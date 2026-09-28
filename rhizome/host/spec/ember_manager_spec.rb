# frozen_string_literal: true

require_relative "../lib/ember_manager"
require "tmpdir"

RSpec.describe EmberManager do
  subject(:manager) {
    described_class.new(max_slots: 4, ip6_block: "2a01:4f8:120:9208:2::/79", ch_version: "53.0", ubiblk_version: "v0.5.1")
  }

  let(:vm) { instance_double(EmberVm) }

  let(:guest_class) {
    Class.new do
      def initialize(slot) = nil

      def wait_ready(timeout:) = nil

      def configure(config) = nil
    end
  }

  let(:guest) { instance_double(guest_class) }

  let(:volume) { instance_double(DetachableVolume, id: "dv1") }

  let(:volume_args) { {volume_id: "dv1", size_gib: 2, kek: "kek", wrapped_xts: "w", source: {"type" => "new", "image" => "seed"}} }

  let(:create_args) {
    {ember_id: "ember1", generation: nil, template_id: "ct1", workload: "fake", **volume_args,
     guest_config: {"superuser_password" => "pw", "database" => "postgres"}, cpu_percent_limit: 50}
  }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  before do
    stub_const("EmberConfig::STATE_DIR", File.join(@root, "state"))
    stub_const("EmberConfig::TEMPLATE_ROOT", File.join(@root, "templates"))
    allow(EmberVm).to receive(:new).and_return(vm)
    allow(vm).to receive_messages(prepare_restore: nil, start: nil, add_disk: nil,
      shutdown: nil, power_button: nil, wait_exit: true, running?: true)
    allow(manager).to receive(:guest_for).and_return(guest)
    allow(guest).to receive_messages(wait_ready: nil, configure: nil)
    allow(DetachableVolume).to receive(:new).and_return(volume)
    allow(volume).to receive_messages(exist?: false, ensure_started: nil, stop: nil,
      destroy: nil, caught_up?: true, vhost_sock: "/vol/vhost.sock", stripes: {}, remote_source?: false)
  end

  describe "#setup" do
    it "prepares the host and builds every slot and the build slot" do
      expect(File).to receive(:exist?).with("/opt/cloud-hypervisor/v53.0/cloud-hypervisor").and_return(true)
      expect(File).to receive(:exist?).with("/opt/cloud-hypervisor/v53.0/ch-remote").and_return(true)
      expect(Dir).to receive(:glob).with(File.expand_path("../lib/guest_*_manager.rb", __dir__)).and_return([])
      expect(FileUtils).to receive(:mkdir_p).with([EmberConfig::VM_ROOT, EmberConfig::STATE_DIR,
        DetachableVolume::IMAGE_ROOT, EmberConfig::TEMPLATE_ROOT, DetachableVolume::ROOT])
      expect(manager).to receive(:r).with("sysctl", "-q", "-w", "net.ipv6.conf.all.forwarding=1")
      expect(manager).to receive(:r).with("sysctl", "-q", "-w", "vm.unprivileged_userfaultfd=1")
      expect(manager).to receive(:safe_write_to_file).with("/etc/systemd/system/ember.slice", /MemoryAccounting=true/)
      expect(manager).to receive(:r).with("systemctl", "daemon-reload")
      5.times do |index|
        slot = instance_double(Slot)
        expect(Slot).to receive(:new).with(index, ip6_block: "2a01:4f8:120:9208:2::/79").and_return(slot)
        expect(slot).to receive(:create)
      end
      expect(manager.setup).to eq({"ok" => true, "slots" => 4})
    end

    it "runs each guest plugin's install hook" do
      expect(File).to receive(:exist?).with("/opt/cloud-hypervisor/v53.0/cloud-hypervisor").and_return(true)
      expect(File).to receive(:exist?).with("/opt/cloud-hypervisor/v53.0/ch-remote").and_return(true)
      path = File.expand_path("../lib/guest_fake_manager.rb", __dir__)
      expect(Dir).to receive(:glob).and_return([path])
      expect(manager).to receive(:require).with(path)
      stub_const("GuestFakeManager", Class.new)
      expect(GuestFakeManager).to receive(:install)
      expect(FileUtils).to receive(:mkdir_p).and_raise(RuntimeError, "stop")
      expect { manager.setup }.to raise_error("stop")
    end

    it "refuses a host without the cloud-hypervisor version embers run, which host prep installs only on newer Ubuntu" do
      expect(File).to receive(:exist?).with("/opt/cloud-hypervisor/v53.0/cloud-hypervisor").and_return(false)
      expect(FileUtils).not_to receive(:mkdir_p)
      expect { manager.setup }.to raise_error(RuntimeError, "cloud-hypervisor 53.0 is not installed")
    end
  end

  describe "#apply_ingress_sources" do
    it "reloads the rules of every slot that exists, the build slot included" do
      5.times do |index|
        slot = instance_double(Slot, exists?: index != 4)
        expect(Slot).to receive(:new).with(index, ip6_block: "2a01:4f8:120:9208:2::/79").and_return(slot)
        if index == 4
          expect(slot).not_to receive(:apply_nftables)
        else
          expect(slot).to receive(:apply_nftables).with(["2a01:4f8:10a:1:2::/80"])
        end
      end
      expect(manager.apply_ingress_sources(["2a01:4f8:10a:1:2::/80"])).to eq({"ok" => true, "sources" => 1})
    end
  end

  describe ".for_template_build" do
    it "is a manager for the host that asked for the build" do
      FileUtils.mkdir_p(EmberConfig::STATE_DIR)
      host = {max_slots: 4, ip6_block: "2a01:4f8:120:9208:2::/79", ch_version: "53.0", ubiblk_version: "v0.5.1"}
      File.write(described_class.template_payload_file("ct1"), JSON.generate({host: host}))
      expect(described_class).to receive(:new).with(max_slots: 4, ip6_block: "2a01:4f8:120:9208:2::/79",
        ch_version: "53.0", ubiblk_version: "v0.5.1").and_return(manager)
      expect(described_class.for_template_build("ct1")).to eq(manager)
    end
  end

  describe "#create" do
    it "holds the ember to its CPU limit" do
      expect(vm).to receive(:start).with(cpu_percent_limit: 50)
      manager.create(**create_args)
    end

    it "stops once the disk is in for a workload with no guest" do
      expect(manager).to receive(:guest_for).and_return(nil)
      expect(manager.create(**create_args)["phases_ms"].keys).to eq([:volume, :restore, :hotplug])
    end

    it "restores into the first free slot and reports where it landed" do
      result = manager.create(**create_args)
      expect(result["slot"]).to eq(0)
      expect(result["ip6"]).to eq("2a01:4f8:120:9208:2::2")
      expect(result["caught_up"]).to be true
      expect(result["phases_ms"]).to include(:volume, :restore, :hotplug, :ready, :configure)
    end

    it "hot-plugs the disk, which is what starts PostgreSQL, then waits for it and configures it" do
      expect(vm).to receive(:add_disk).with("/vol/vhost.sock").ordered
      expect(guest).to receive(:wait_ready).with(timeout: 180).ordered
      expect(guest).to receive(:configure).with({"superuser_password" => "pw", "database" => "postgres"}).ordered
      manager.create(**create_args)
    end

    it "starts catching up from another host only once the ember is serving" do
      allow(volume).to receive_messages(remote_source?: true, caught_up?: false)
      expect(guest).to receive(:configure).ordered
      expect(volume).to receive(:start_autofetch).ordered
      manager.create(**create_args)
    end

    it "does not catch up a volume that is already caught up, or one seeded from an image" do
      allow(volume).to receive_messages(remote_source?: true, caught_up?: true)
      expect(volume).not_to receive(:start_autofetch)
      manager.create(**create_args)
      allow(volume).to receive_messages(remote_source?: false, caught_up?: false)
      manager.create(**create_args, ember_id: "ember2")
    end

    it "refuses a volume that is not here and has nowhere to read from, rather than lay it out empty" do
      args = create_args.merge(source: nil)
      expect(volume).not_to receive(:ensure_started)
      expect { manager.create(**args) }.to raise_error(EmberManager::NotFound, "volume dv1 is not on this host")
    end

    it "starts a volume that is already here without a source" do
      allow(volume).to receive(:exist?).and_return(true)
      args = create_args.merge(source: nil)
      expect(manager.create(**args)["slot"]).to eq(0)
    end

    it "frees the slot when the VM never came up" do
      expect(EmberVm).to receive(:new).and_raise("no hypervisor")
      expect { manager.create(**create_args) }.to raise_error(RuntimeError, /no hypervisor/)
      expect(manager.list["slots"]).to be_empty
    end

    it "tears the VM down when PostgreSQL never comes up" do
      expect(guest).to receive(:wait_ready).and_raise(RuntimeError, "not within 180s")
      expect(vm).to receive(:shutdown)
      expect(volume).to receive(:stop)
      expect { manager.create(**create_args) }.to raise_error(RuntimeError, "not within 180s")
      expect(manager.list["slots"]).to be_empty
    end

    it "refuses once every slot is taken" do
      4.times { |i| manager.create(**create_args, ember_id: "ember#{i}") }
      expect { manager.create(**create_args, ember_id: "ember9") }
        .to raise_error(described_class::SlotExhausted)
    end

    it "frees the slot again when the restore fails partway" do
      expect(vm).to receive(:start).and_raise("restore failed")
      expect { manager.create(**create_args) }.to raise_error(RuntimeError, /restore failed/)
      expect(manager.list["slots"]).to be_empty
    end

    it "starts the volume as the slot's user, in the embers' slice, laying it out if it is new" do
      expect(volume).to receive(:ensure_started).with(kek: "kek", unix_user: "emslot0000", device_id: "cldata", slice: "ember.slice",
        size_gib: 2, wrapped_xts: "w", source: {"type" => "new", "image" => "seed"})
      manager.create(**create_args)
    end
  end

  describe "#claim_blank" do
    before { manager.create_blank(template_id: "ct1", workload: "fake", **volume_args, guest_config: {"superuser_password" => "blank"}, cpu_percent_limit: 50) }

    it "reconfigures the guest rather than restoring, and says which volume it handed over" do
      expect(vm).not_to receive(:prepare_restore)
      expect(guest).to receive(:configure).with({"superuser_password" => "pw"})
      result = manager.claim_blank(ember_id: "ember1", generation: nil, template_id: "ct1", workload: "fake", guest_config: {"superuser_password" => "pw"})
      expect(result["volume_id"]).to eq("dv1")
      expect(result["slot"]).to eq(0)
      expect(result["phases_ms"]).to have_key(:claim)
    end

    it "only hands over a blank of the same template" do
      expect { manager.claim_blank(ember_id: "ember1", generation: nil, template_id: "ct2", workload: "fake", guest_config: {}) }
        .to raise_error(described_class::SlotExhausted)
    end

    it "refuses when there is no blank left" do
      manager.claim_blank(ember_id: "ember1", generation: nil, template_id: "ct1", workload: "fake", guest_config: {})
      expect { manager.claim_blank(ember_id: "ember2", generation: nil, template_id: "ct1", workload: "fake", guest_config: {}) }
        .to raise_error(described_class::SlotExhausted)
    end
  end

  describe "#create_blank" do
    it "holds the blank, configured as the caller asked, until something claims it" do
      expect(guest).to receive(:configure).with({"superuser_password" => "blank"})
      result = manager.create_blank(template_id: "ct1", workload: "fake", **volume_args, guest_config: {"superuser_password" => "blank"}, cpu_percent_limit: 50)
      expect(result["volume_id"]).to eq("dv1")
      # A blank is named by its volume, which the control plane already knows.
      expect(manager.list["slots"]).to eq([{"slot" => 0, "kind" => "blank", "id" => "dv1", "volume_id" => "dv1"}])
    end
  end

  describe "#pause" do
    before { manager.create(**create_args) }

    it "presses the power button, and a guest that powers off by itself went down cleanly" do
      expect(vm).to receive(:power_button).ordered
      expect(vm).to receive(:wait_exit).with(timeout: 60).and_return(true).ordered
      # The VM goes before the backend, or cloud-hypervisor retries the vhost
      # socket for a minute.
      expect(vm).to receive(:shutdown).ordered
      expect(volume).to receive(:stop).ordered
      result = manager.pause("ember1", generation: nil)
      expect(result["clean"]).to be true
      expect(manager.list["slots"]).to be_empty
    end

    it "stops a guest that does not power off, and calls it unclean" do
      expect(vm).to receive(:wait_exit).and_return(false)
      expect(vm).to receive(:shutdown)
      expect { expect(manager.pause("ember1", generation: nil)["clean"]).to be false }.to output(/did not power off/).to_stderr
    end

    it "stops a guest whose power button cannot be pressed, and calls it unclean" do
      expect(vm).to receive(:power_button).and_raise("cloud-hypervisor gone")
      expect(vm).to receive(:shutdown)
      expect { expect(manager.pause("ember1", generation: nil)["clean"]).to be false }.to output(/cloud-hypervisor gone/).to_stderr
    end

    it "refuses an ember it has never heard of" do
      expect { manager.pause("nope", generation: nil) }.to raise_error(described_class::NotFound)
    end

    it "refuses a request issued against a stale view of the world" do
      manager.pause("ember1", generation: 5)
      expect { manager.pause("ember1", generation: 4) }
        .to raise_error(described_class::StaleGeneration)
    end
  end

  describe "#destroy" do
    it "says yes about an ember that is already gone" do
      expect(manager.destroy("nope", generation: nil, delete_volume: false)).to eq({"destroyed" => true})
    end

    it "pauses first, and keeps the volume unless asked otherwise" do
      manager.create(**create_args)
      expect(volume).not_to receive(:destroy)
      expect(manager.destroy("ember1", generation: nil, delete_volume: false)).to eq({"destroyed" => true})
    end

    it "takes the volume when asked" do
      manager.create(**create_args)
      expect(volume).to receive(:destroy)
      manager.destroy("ember1", generation: nil, delete_volume: true)
    end
  end

  describe "#describe" do
    it "is absent for an ember no slot holds" do
      expect(manager.describe("nope")).to eq({"state" => "absent"})
    end

    it "reports the slot and address of one that is running" do
      manager.create(**create_args)
      expect(manager.describe("ember1"))
        .to eq({"state" => "running", "slot" => 0, "ip6" => "2a01:4f8:120:9208:2::2"})
    end

    it "is absent when the slot is recorded but the VM is not running" do
      manager.create(**create_args)
      allow(vm).to receive(:running?).and_return(false)
      expect(manager.describe("ember1")["state"]).to eq("absent")
    end
  end

  describe "#list" do
    it "says what each occupied slot holds" do
      manager.create_blank(template_id: "ct1", workload: "fake", **volume_args, guest_config: {"superuser_password" => "blank"}, cpu_percent_limit: 50)
      manager.create(**create_args, volume_id: "dv2")
      expect(manager.list["slots"]).to eq([
        {"slot" => 0, "kind" => "blank", "id" => "dv1", "volume_id" => "dv1"},
        {"slot" => 1, "kind" => "ember", "id" => "ember1", "volume_id" => "dv2"},
      ])
    end
  end

  describe "#configure" do
    it "changes a running ember's password" do
      manager.create(**create_args)
      expect(guest).to receive(:configure).with({"superuser_password" => "new"})
      manager.configure("ember1", generation: nil, workload: "fake", guest_config: {"superuser_password" => "new"})
    end

    it "refuses an ember that is not here" do
      expect { manager.configure("nope", generation: nil, workload: "fake", guest_config: {}) }.to raise_error(described_class::NotFound)
    end

    it "refuses a workload with no guest to configure" do
      manager.create(**create_args)
      expect(manager).to receive(:guest_for).and_return(nil)
      expect { manager.configure("ember1", generation: nil, workload: "fake", guest_config: {}) }
        .to raise_error(ArgumentError, "fake embers have nothing to configure")
    end
  end

  describe "#guest_for" do
    let(:unstubbed) { described_class.new(max_slots: 4, ip6_block: "2a01:4f8:120:9208:2::/79", ch_version: "53.0", ubiblk_version: "v0.5.1") }
    let(:slot) { Slot.new(0, ip6_block: "2a01:4f8:120:9208:2::/79") }

    it "has no guest for a workload that ships none" do
      expect(unstubbed.send(:guest_for, "nothing", slot)).to be_nil
    end

    it "loads the workload's guest by name" do
      path = File.expand_path("../lib/guest_fake_manager.rb", __dir__)
      manager = unstubbed
      expect(File).to receive(:exist?).with(path).and_return(true)
      expect(manager).to receive(:require).with(path)
      stub_const("GuestFakeManager", guest_class)
      expect(manager.send(:guest_for, "fake", slot)).to be_a(guest_class)
    end

    it "only takes a workload name, so it cannot load a file from elsewhere" do
      expect { unstubbed.send(:guest_for, "../x", slot) }.to raise_error(ArgumentError, 'invalid workload "../x"')
    end
  end

  describe "templates" do
    it "is absent before anything has been built" do
      expect(manager.template_status("ct1")).to eq({"state" => "absent"})
    end

    it "starts the build as a unit of its own, so the command returns at once" do
      expect(manager).to receive(:r) { |*cmd|
        expect(cmd.first(5)).to eq(["systemd-run", "--unit", "ember-template-ct1", "--collect", "--quiet"])
        expect(cmd.last(3)).to eq([File.expand_path("../bin/ember", __dir__), "run-template-build", "ct1"])
      }
      expect(manager.build_template("ct1", root_image: "root", memory_mib: 384, vcpus: 1, ch_version: "53.0")).to eq({"state" => "building"})
      expect(manager.template_status("ct1")).to eq({"state" => "building"})
      expect(JSON.parse(File.read(described_class.template_payload_file("ct1"))))
        .to eq({"root_image" => "root", "memory_mib" => 384, "vcpus" => 1, "ch_version" => "53.0",
          "host" => {"max_slots" => 4, "ip6_block" => "2a01:4f8:120:9208:2::/79", "ch_version" => "53.0", "ubiblk_version" => "v0.5.1"}})
    end

    it "records a build that finished, and drops its payload" do
      manager.send(:write_template_state, "ct1", {"state" => "building"})
      File.write(described_class.template_payload_file("ct1"), JSON.generate({root_image: "root", memory_mib: 384, vcpus: 1, ch_version: "53.0", host: {}}))
      expect(manager).to receive(:build_template_snapshot).with("ct1", root_image: "root", memory_mib: 384, vcpus: 1, ch_version: "53.0")
      manager.run_template_build("ct1")
      expect(manager.template_status("ct1")).to eq({"state" => "ready"})
      expect(File.exist?(described_class.template_payload_file("ct1"))).to be false
    end

    it "records a build that failed" do
      FileUtils.mkdir_p(EmberConfig::STATE_DIR)
      File.write(described_class.template_payload_file("ct1"), "{}")
      expect(manager).to receive(:build_template_snapshot).and_raise("guest never quiesced")
      manager.run_template_build("ct1")
      expect(manager.template_status("ct1")).to eq({"state" => "failed", "detail" => "guest never quiesced"})
    end

    it "deletes a template and forgets its state" do
      manager.send(:write_template_state, "ct1", {"state" => "ready"})
      expect(manager.delete_template("ct1")).to eq({"deleted" => true})
      expect(manager.template_status("ct1")).to eq({"state" => "absent"})
    end
  end

  describe "#build_slot" do
    it "is outside the ember range, so a build never competes for a slot" do
      slot = manager.send(:build_slot)
      expect(slot.index).to eq(4)
      expect(slot.name).to eq("emslot0004")
    end
  end

  describe "#build_template_snapshot" do
    let(:build_slot) { instance_double(Slot, name: "emslot0004", dir: "/vm/emslot0004") }

    before do
      allow(manager).to receive(:build_slot).and_return(build_slot)
      allow(build_slot).to receive_messages(exists?: true, create: nil)
      allow(vm).to receive_messages(boot: nil, wait_serial: true, pause_vm: nil, snapshot: nil)
      allow(manager).to receive(:sleep)
      allow(FileUtils).to receive(:rm_rf)
    end

    it "boots cold, waits for the guest to say it has settled, snapshots, and shuts the VM down" do
      expect(vm).to receive(:boot).with(root_image: "/var/storage/images/root.raw",
        memory_mib: 384, vcpus: 1).ordered
      expect(vm).to receive(:wait_serial).with("CELL-TEMPLATE-READY", timeout: 300).ordered
      expect(vm).to receive(:pause_vm).ordered
      expect(vm).to receive(:snapshot).with(EmberConfig.template_dir("ct1")).ordered
      expect(vm).to receive(:shutdown).ordered
      manager.send(:build_template_snapshot, "ct1", root_image: "root", memory_mib: 384, vcpus: 1, ch_version: "53.0")
    end

    it "builds the slot if it is not there yet" do
      allow(build_slot).to receive(:exists?).and_return(false)
      expect(build_slot).to receive(:create).with(no_args)
      manager.send(:build_template_snapshot, "ct1", root_image: "root", memory_mib: 384, vcpus: 1, ch_version: "53.0")
    end

    it "shuts the VM down even when the build fails" do
      expect(vm).to receive(:boot).and_raise("no such image")
      expect(vm).to receive(:shutdown)
      expect { manager.send(:build_template_snapshot, "ct1", root_image: "r", memory_mib: 1, vcpus: 1, ch_version: "53.0") }
        .to raise_error(RuntimeError, /no such image/)
    end
  end

  describe "#teardown" do
    it "does not let a failure rolling back hide the failure that caused it" do
      expect(vm).to receive(:shutdown).and_raise("already gone")
      expect { manager.send(:teardown, vm, volume) }.not_to raise_error
    end

    it "has nothing to roll back when the create failed before either existed" do
      expect { manager.send(:teardown, nil, nil) }.not_to raise_error
    end
  end

  describe "a slot with no volume" do
    # A blank whose volume was cleared, or state written by an older version:
    # everything still has to work without one.
    before do
      manager.create(**create_args)
      manager.send(:record, 0, ember_id: "ember1", kind: "ember")
    end

    it "pauses, and calls itself caught up because there is nothing to catch up" do
      expect(volume).not_to receive(:stop)
      expect(manager.pause("ember1", generation: nil)["caught_up"]).to be true
    end

    it "has no volume to delete" do
      expect(volume).not_to receive(:destroy)
      expect(manager.destroy("ember1", generation: nil, delete_volume: true)).to eq({"destroyed" => true})
    end
  end

  describe "state on disk" do
    it "survives a restart" do
      manager.create(**create_args)
      revived = described_class.new(max_slots: 4, ip6_block: "2a01:4f8:120:9208:2::/79", ch_version: "53.0", ubiblk_version: "v0.5.1")
      expect(revived.describe("ember1")["slot"]).to eq(0)
    end

    it "refuses to start on a corrupt state file rather than hand out slots that may be taken" do
      manager.create(**create_args)
      File.write(manager.state_file, "not json")
      expect { described_class.new(max_slots: 4, ip6_block: "2a01:4f8:120:9208:2::/79", ch_version: "53.0", ubiblk_version: "v0.5.1") }
        .to raise_error(JSON::ParserError)
    end

    # Each host/bin/ember command is its own process with its own EmberManager, so
    # what one records the next has to find on disk.
    def another_process
      described_class.new(max_slots: 4, ip6_block: "2a01:4f8:120:9208:2::/79", ch_version: "53.0", ubiblk_version: "v0.5.1")
    end

    it "gives two creates in separate processes different slots" do
      first = another_process
      second = another_process
      expect(first.create(**create_args)["slot"]).to eq(0)
      expect(second.create(**create_args, ember_id: "ember2")["slot"]).to eq(1)
    end

    it "does not hand one blank to two claims" do
      manager.create_blank(template_id: "ct1", workload: "fake", **volume_args, guest_config: {"superuser_password" => "blank"}, cpu_percent_limit: 50)
      another_process.claim_blank(ember_id: "ember1", generation: nil, template_id: "ct1", workload: "fake", guest_config: {})
      expect { another_process.claim_blank(ember_id: "ember2", generation: nil, template_id: "ct1", workload: "fake", guest_config: {}) }
        .to raise_error(described_class::SlotExhausted)
    end

    it "remembers generations across processes" do
      manager.create(**create_args, generation: 3)
      expect { another_process.pause("ember1", generation: 2) }
        .to raise_error(described_class::StaleGeneration)
    end
  end
end
