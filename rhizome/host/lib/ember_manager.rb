# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "cloud_hypervisor"
require_relative "ember_config"
require_relative "slot"
require_relative "ember_vm"
require_relative "detachable_volume"
require "fileutils"
require "json"

class EmberManager
  class SlotExhausted < StandardError; end

  class NotFound < StandardError; end

  class StaleGeneration < StandardError; end

  attr_reader :slots

  def self.for_template_build(template_id)
    new(**JSON.parse(File.read(template_payload_file(template_id))).fetch("host").transform_keys(&:to_sym))
  end

  def self.template_payload_file(template_id)
    File.join(EmberConfig::STATE_DIR, "template-#{template_id}-payload.json")
  end

  def initialize(max_slots:, ip6_block:, ch_version:, ubiblk_version:)
    @max_slots = max_slots
    @ip6_block = ip6_block
    @ch_version = ch_version
    @ubiblk_version = ubiblk_version
    @slots = {}
    @generations = {}
    load_state
  end

  def state_file = File.join(EmberConfig::STATE_DIR, "state.json")

  def generations_file = File.join(EmberConfig::STATE_DIR, "generations.json")

  def lock_file = File.join(EmberConfig::STATE_DIR, "state.lock")

  def setup
    fail "cloud-hypervisor #{@ch_version} is not installed" unless CloudHypervisor::Version.new(@ch_version).downloaded?

    Dir.glob(File.join(__dir__, "guest_*_manager.rb")).each do |path|
      require path
      Object.const_get(File.basename(path, ".rb").split("_").map(&:capitalize).join).install
    end

    FileUtils.mkdir_p([EmberConfig::VM_ROOT, EmberConfig::STATE_DIR, DetachableVolume::IMAGE_ROOT,
      EmberConfig::TEMPLATE_ROOT, DetachableVolume::ROOT])

    r("sysctl", "-q", "-w", "net.ipv6.conf.all.forwarding=1")
    r("sysctl", "-q", "-w", "vm.unprivileged_userfaultfd=1")

    safe_write_to_file("/etc/systemd/system/ember.slice", <<~SLICE)
      [Unit]
      Description=Embers
      Before=slices.target

      [Slice]
      CPUAccounting=true
      MemoryAccounting=true
    SLICE
    r("systemctl", "daemon-reload")

    (0..@max_slots).each { |index| Slot.new(index, ip6_block: @ip6_block).create }
    {"ok" => true, "slots" => @max_slots}
  end

  def apply_ingress_sources(sources)
    (0..@max_slots).each do |index|
      slot = Slot.new(index, ip6_block: @ip6_block)
      slot.apply_nftables(sources) if slot.exists?
    end
    {"ok" => true, "sources" => sources.length}
  end

  def create(ember_id:, generation:, template_id:, workload:, volume_id:, size_gib:, kek:, wrapped_xts:, source:, guest_config:, cpu_percent_limit:)
    unless source || DetachableVolume.new(volume_id).exist?
      fail NotFound, "volume #{volume_id} is not on this host"
    end

    phases = {}
    started = monotonic
    index = locked do
      check_generation(ember_id, generation)
      claim_free_slot(ember_id)
    end
    fail SlotExhausted, "no free slot" unless index

    slot = Slot.new(index, ip6_block: @ip6_block)
    volume = nil
    vm = nil
    begin
      volume = DetachableVolume.new(volume_id, ubiblk_version: @ubiblk_version)
      volume.ensure_started(kek: kek, unix_user: slot.name, device_id: "cldata", slice: "ember.slice",
        size_gib: size_gib, wrapped_xts: wrapped_xts, source: source)
      phases[:volume] = elapsed(started)

      vm = EmberVm.new(slot, ch_version: @ch_version)
      vm.prepare_restore(EmberConfig.template_dir(template_id))
      vm.start(cpu_percent_limit: cpu_percent_limit)
      phases[:restore] = elapsed(started)

      vm.add_disk(volume.vhost_sock)
      phases[:hotplug] = elapsed(started)

      if (guest = guest_for(workload, slot))
        guest.wait_ready(timeout: 180)
        phases[:ready] = elapsed(started)

        guest.configure(guest_config)
        phases[:configure] = elapsed(started)
      end

      volume.start_autofetch if volume.remote_source? && !volume.caught_up?
    rescue
      teardown(vm, volume)
      locked { release_slot(index) }
      raise
    end

    record(index, ember_id: ember_id, volume_id: volume_id, kind: "ember")
    {
      "slot" => index,
      "ip6" => slot.public_ip6,
      "caught_up" => volume.caught_up?,
      "phases_ms" => phases,
    }
  end

  def claim_blank(ember_id:, generation:, template_id:, workload:, guest_config:)
    started = monotonic
    index = locked do
      check_generation(ember_id, generation)
      found = @slots.keys.find { |i| @slots[i][:kind] == "blank" && @slots[i][:template_id] == template_id }
      @slots[found] = @slots[found].merge(kind: "claiming", ember_id: ember_id) if found
      found
    end
    fail SlotExhausted, "no blank available" unless index

    slot = Slot.new(index, ip6_block: @ip6_block)
    guest_for(workload, slot)&.configure(guest_config)

    volume_id = @slots[index][:volume_id]
    record(index, ember_id: ember_id, volume_id: volume_id, kind: "ember")
    {
      "slot" => index,
      "ip6" => slot.public_ip6,
      "volume_id" => volume_id,
      "caught_up" => true,
      "phases_ms" => {claim: elapsed(started)},
    }
  end

  def pause(ember_id, generation:)
    locked { check_generation(ember_id, generation) }
    index = slot_index_for(ember_id)
    fail NotFound, "no such ember" unless index

    started = monotonic
    slot = Slot.new(index, ip6_block: @ip6_block)
    vm = EmberVm.new(slot, ch_version: @ch_version)
    volume = volume_for(index)

    clean = begin
      vm.power_button
      vm.wait_exit(timeout: 60)
    rescue => e
      warn "pause: power button failed for #{ember_id}: #{e.message}"
      false
    end
    warn "pause: #{ember_id} did not power off, stopping it" unless clean

    vm.shutdown
    volume&.stop
    locked { release_slot(index) }

    {"clean" => clean, "caught_up" => volume ? volume.caught_up? : true,
     "phases_ms" => {total: elapsed(started)}}
  end

  def destroy(ember_id, generation:, delete_volume:)
    index = slot_index_for(ember_id)
    return {"destroyed" => true} unless index

    volume = volume_for(index)
    pause(ember_id, generation: generation)
    volume&.destroy if delete_volume
    {"destroyed" => true}
  end

  def describe(ember_id)
    index = slot_index_for(ember_id)
    return {"state" => "absent"} unless index

    slot = Slot.new(index, ip6_block: @ip6_block)
    vm = EmberVm.new(slot, ch_version: @ch_version)
    {"state" => vm.running? ? "running" : "absent", "slot" => index, "ip6" => slot.public_ip6}
  end

  def list
    {"slots" => @slots.sort.map do |index, entry|
      {"slot" => index, "kind" => entry[:kind], "id" => entry[:ember_id], "volume_id" => entry[:volume_id]}
    end}
  end

  def configure(ember_id, generation:, workload:, guest_config:)
    locked { check_generation(ember_id, generation) }
    index = slot_index_for(ember_id)
    fail NotFound, "no such ember" unless index

    guest = guest_for(workload, Slot.new(index, ip6_block: @ip6_block))
    fail ArgumentError, "#{workload} embers have nothing to configure" unless guest
    guest.configure(guest_config)
    {"ok" => true}
  end

  def create_blank(template_id:, workload:, volume_id:, size_gib:, kek:, wrapped_xts:, source:, guest_config:, cpu_percent_limit:)
    result = create(ember_id: volume_id, generation: nil, template_id: template_id, workload: workload, volume_id: volume_id,
      size_gib: size_gib, kek: kek, wrapped_xts: wrapped_xts, source: source, guest_config: guest_config,
      cpu_percent_limit: cpu_percent_limit)
    record(result.fetch("slot"), ember_id: volume_id, volume_id: volume_id, kind: "blank", template_id: template_id)
    result.merge("volume_id" => volume_id)
  end

  def build_template(template_id, root_image:, memory_mib:, vcpus:, ch_version:)
    write_template_state(template_id, {"state" => "building"})
    safe_write_to_file(self.class.template_payload_file(template_id), JSON.generate({
      root_image: root_image, memory_mib: memory_mib, vcpus: vcpus, ch_version: ch_version,
      host: {max_slots: @max_slots, ip6_block: @ip6_block, ch_version: @ch_version, ubiblk_version: @ubiblk_version},
    }))
    r("systemd-run", "--unit", "ember-template-#{template_id}", "--collect", "--quiet",
      "--working-directory", File.expand_path("../..", __dir__),
      File.expand_path("../bin/ember", __dir__), "run-template-build", template_id)
    {"state" => "building"}
  end

  def run_template_build(template_id)
    params = JSON.parse(File.read(self.class.template_payload_file(template_id)), symbolize_names: true)
    build_template_snapshot(template_id, **params.except(:host))
    write_template_state(template_id, {"state" => "ready"})
  rescue => e
    warn "template build #{template_id} failed: #{e.message}"
    write_template_state(template_id, {"state" => "failed", "detail" => e.message})
  ensure
    FileUtils.rm_f(self.class.template_payload_file(template_id))
  end

  def template_status(template_id)
    read_template_state(template_id)
  end

  def delete_template(template_id)
    FileUtils.rm_rf(EmberConfig.template_dir(template_id))
    FileUtils.rm_f(template_state_file(template_id))
    {"deleted" => true}
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def elapsed(from) = ((monotonic - from) * 1000).round(1)

  def locked
    FileUtils.mkdir_p(EmberConfig::STATE_DIR)
    File.open(lock_file, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      load_state
      result = yield
      persist
      result
    end
  end

  def check_generation(ember_id, generation)
    return if generation.nil?
    seen = @generations[ember_id]
    fail StaleGeneration, "generation #{generation} is behind #{seen}" if seen && generation < seen
    @generations[ember_id] = generation
  end

  def claim_free_slot(ember_id)
    index = (0...@max_slots).find { |i| !@slots.key?(i) }
    @slots[index] = {kind: "claiming", ember_id: ember_id} if index
    index
  end

  def release_slot(index)
    @slots.delete(index)
  end

  def record(index, **attrs)
    locked { @slots[index] = attrs }
  end

  def slot_index_for(ember_id)
    @slots.keys.find { |i| @slots[i][:ember_id] == ember_id }
  end

  def volume_for(index)
    volume_id = @slots.dig(index, :volume_id)
    volume_id && DetachableVolume.new(volume_id, ubiblk_version: @ubiblk_version)
  end

  def guest_for(workload, slot)
    fail ArgumentError, "invalid workload #{workload.inspect}" unless /\A[a-z]+\z/.match?(workload)
    path = File.join(__dir__, "guest_#{workload}_manager.rb")
    return unless File.exist?(path)
    require path
    Object.const_get("Guest#{workload.capitalize}Manager").new(slot)
  end

  def teardown(vm, volume)
    vm&.shutdown
    volume&.stop
  rescue
    nil
  end

  def template_state_file(template_id)
    File.join(EmberConfig::STATE_DIR, "template-#{template_id}.json")
  end

  def write_template_state(template_id, state)
    FileUtils.mkdir_p(EmberConfig::STATE_DIR)
    safe_write_to_file(template_state_file(template_id), JSON.generate(state))
  end

  def read_template_state(template_id)
    path = template_state_file(template_id)
    File.exist?(path) ? JSON.parse(File.read(path)) : {"state" => "absent"}
  end

  def build_slot
    Slot.new(@max_slots, ip6_block: @ip6_block)
  end

  def build_template_snapshot(template_id, root_image:, memory_mib:, vcpus:, ch_version:)
    slot = build_slot
    slot.create unless slot.exists?
    vm = EmberVm.new(slot, ch_version: ch_version)
    dir = EmberConfig.template_dir(template_id)
    FileUtils.rm_rf(dir)

    begin
      vm.boot(root_image: File.join(DetachableVolume::IMAGE_ROOT, "#{root_image}.raw"), memory_mib: memory_mib, vcpus: vcpus)
      vm.wait_serial("CELL-TEMPLATE-READY", timeout: 300)
      sleep 2
      vm.pause_vm
      vm.snapshot(dir)
    ensure
      vm.shutdown
    end
  end

  def persist
    FileUtils.mkdir_p(EmberConfig::STATE_DIR)
    safe_write_to_file(state_file) { |f| f.write(JSON.generate(@slots)) }
    safe_write_to_file(generations_file) { |f| f.write(JSON.generate(@generations)) }
  end

  def load_state
    @slots = read_json(state_file).to_h { |index, entry| [index.to_i, entry.transform_keys(&:to_sym)] }
    @generations = read_json(generations_file)
  end

  def read_json(path)
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  end
end
