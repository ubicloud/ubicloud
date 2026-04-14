# frozen_string_literal: true

require_relative "spec_helper"

# Real two-connection concurrency specs for the GCP 9-firewall-per-VM cap
# row lock. The cap is enforced by Firewall.lock_subnet_for_gcp_cap!, which
# does SELECT ... FOR UPDATE on the private_subnet row and is called from
# both Prog::Vm::Nexus.assemble and Firewall#associate_with_private_subnet
# before the cap is read. The "simulated race" specs in
# spec/model/firewall_spec.rb and spec/prog/vm/gcp/nexus_spec.rb stub the
# lock helper and inject peer writes inside the same RSpec transaction, so
# they do not actually exercise cross-transaction blocking — a regression
# that silently dropped FOR UPDATE would still make those specs green.
#
# These specs check out two real DB connections via separate threads, drive
# them through barriers, and assert (a) the second transaction blocks on
# the row lock while the first holds it and (b) two concurrent attempts to
# attach a firewall never push the VM over the 9 cap.
#
# They opt out of the wrapping rollback-only transaction in spec_helper
# (see :no_db_transaction metadata) and clean up their own committed rows
# in the after hook.
RSpec.describe Firewall, :no_db_transaction do
  # Skip the outer leaked-thread audit: the worker threads we spawn here
  # are joined explicitly, but the Sequel pool may retain idle connection
  # threads that look like leaks to the default checker.
  before { @skip_leaked_thread_check = true }

  let(:tag) { SecureRandom.hex(4) }
  let(:created) {
    {
      nics: [],
      firewalls_private_subnets: [],
      firewalls: [],
      vms: [],
      private_subnets: [],
      locations: [],
      projects: [],
    }
  }

  def make_project
    project = Project.create(name: "fw-cc-#{tag}-#{created[:projects].size}")
    created[:projects] << project.id
    project
  end

  def make_gcp_location(project_id)
    location = Location.create(
      name: "fw-cc-gcp-#{tag}-#{created[:locations].size}",
      provider: "gcp",
      display_name: "FW CC GCP",
      ui_name: "FW CC GCP",
      visible: true,
      project_id:,
    )
    created[:locations] << location.id
    location
  end

  def make_subnet(location_id, project_id)
    idx = created[:private_subnets].size
    subnet = PrivateSubnet.create(
      name: "fw-cc-ps-#{tag}-#{idx}",
      location_id:, project_id:,
      net6: "fd10:cc#{format("%02x", idx)}::/64",
      net4: "10.#{100 + idx}.0.0/26",
      state: "active",
    )
    created[:private_subnets] << subnet.id
    subnet
  end

  def make_fw(location_id, project_id, name)
    fw = Firewall.create(name: "#{name}-#{tag}", description: "d", location_id:, project_id:)
    created[:firewalls] << fw.id
    fw
  end

  def attach_vm(project_id, location_id, subnet, idx)
    vm = Vm.create(
      unix_user: "ubi", public_key: "ssh-ed25519 key",
      name: "fw-cc-vm-#{tag}-#{idx}",
      family: "standard", cores: 0, vcpus: 2,
      cpu_percent_limit: 200, cpu_burst_percent_limit: 0,
      memory_gib: 8, arch: "x64",
      location_id:, project_id:,
      boot_image: "ubuntu-jammy", display_state: "running",
      ip4_enabled: false, created_at: Time.now,
    )
    created[:vms] << vm.id
    Nic.create(
      private_subnet_id: subnet.id, vm_id: vm.id,
      name: "nic-#{idx}-#{tag}",
      private_ipv4: subnet.net4.nth(idx + 2).to_s,
      private_ipv6: subnet.net6.nth(idx + 2).to_s,
      mac: "00:00:00:00:%02x:%02x" % [idx, created[:vms].size],
      state: "active",
    ).tap { created[:nics] << it.id }
    vm
  end

  after do
    # Delete in reverse dependency order. Use a single transaction on the
    # main thread's connection so partial failures roll back cleanly.
    DB.transaction do
      DB[:nic].where(id: created[:nics]).delete unless created[:nics].empty?
      unless created[:firewalls].empty?
        DB[:firewalls_private_subnets].where(firewall_id: created[:firewalls]).delete
        DB[:firewalls_vms].where(firewall_id: created[:firewalls]).delete
        DB[:firewall_rule].where(firewall_id: created[:firewalls]).delete
      end
      DB[:vm].where(id: created[:vms]).delete unless created[:vms].empty?
      DB[:firewall].where(id: created[:firewalls]).delete unless created[:firewalls].empty?
      DB[:private_subnet].where(id: created[:private_subnets]).delete unless created[:private_subnets].empty?
      DB[:location].where(id: created[:locations]).delete unless created[:locations].empty?
      DB[:project].where(id: created[:projects]).delete unless created[:projects].empty?
    end
  end

  it "blocks a second transaction that tries to acquire the same subnet row lock" do
    project = make_project
    location = make_gcp_location(project.id)
    subnet = make_subnet(location.id, project.id)

    t1_has_lock = Queue.new
    t1_may_release = Queue.new
    t2_done = Queue.new
    t2_wait_start = nil
    t2_unblocked_at = nil
    t1_error = nil
    t2_error = nil

    t1 = Thread.new do
      DB.transaction do
        described_class.lock_subnet_for_gcp_cap!(subnet)
        t1_has_lock.push(true)
        t1_may_release.pop
      end
    rescue => e
      t1_error = e
    end

    begin
      t1_has_lock.pop
      t2 = Thread.new do
        t2_wait_start = Time.now
        DB.transaction do
          described_class.lock_subnet_for_gcp_cap!(subnet)
          t2_unblocked_at = Time.now
        end
        t2_done.push(true)
      rescue => e
        t2_error = e
        t2_done.push(true)
      end

      # Give T2 time to enter the blocking wait on T1's row lock.
      sleep 0.25
      expect(t2.alive?).to be true
      expect(t2_unblocked_at).to be_nil

      t1_may_release.push(true)
      t1.join(5)
      t2_done.pop
      t2.join(5)
    ensure
      t1_may_release.push(true) if t1.alive?
      t1.join(5)
      t2&.join(5)
    end

    expect(t1_error).to be_nil
    expect(t2_error).to be_nil
    expect(t2_unblocked_at).not_to be_nil
    expect(t2_unblocked_at - t2_wait_start).to be >= 0.2
  end

  it "serializes two concurrent firewall attaches so the cap is never exceeded" do
    project = make_project
    location = make_gcp_location(project.id)
    subnet = make_subnet(location.id, project.id)
    attach_vm(project.id, location.id, subnet, 1)

    8.times do |i|
      make_fw(location.id, project.id, "seed-#{i}")
        .associate_with_private_subnet(subnet, apply_firewalls: false)
    end
    expect(subnet.firewalls_dataset.count).to eq(8)

    fw9 = make_fw(location.id, project.id, "race-9")
    fw10 = make_fw(location.id, project.id, "race-10")

    # Force an interleave where the first thread to reach the cap check
    # stalls long enough for the second thread to race in. With the row
    # lock in place, the second thread is blocked at lock acquisition and
    # never reaches the cap check until the first commits, so the stall
    # fires exactly once. Without the lock, both threads read the cap as
    # 8 concurrently, both pass, and both commit → count becomes 10.
    validate_calls = Mutex.new
    validate_count = 0
    allow(described_class).to receive(:validate_gcp_firewall_cap!).and_wrap_original do |m, *args, **kw|
      m.call(*args, **kw)
      should_stall = validate_calls.synchronize { (validate_count += 1) == 1 }
      sleep 0.4 if should_stall
    end

    start_barrier = Queue.new
    results = Array.new(2)

    workers = [fw9, fw10].each_with_index.map do |fw, i|
      Thread.new do
        start_barrier.pop
        fw.associate_with_private_subnet(subnet, apply_firewalls: false)
        results[i] = :ok
      rescue Validation::ValidationFailed
        results[i] = :cap_rejected
      rescue => e
        results[i] = [:error, e.class.name, e.message]
      end
    end
    2.times { start_barrier.push(true) }
    workers.each { |t| t.join(10) }

    expect(results.count(:ok)).to eq(1)
    expect(results.count(:cap_rejected)).to eq(1)
    expect(subnet.firewalls_dataset.count).to eq(9)
  end

  it "lets the second transaction observe the first's committed attach through the lock" do
    project = make_project
    location = make_gcp_location(project.id)
    subnet = make_subnet(location.id, project.id)
    attach_vm(project.id, location.id, subnet, 1)

    8.times do |i|
      make_fw(location.id, project.id, "seed-#{i}")
        .associate_with_private_subnet(subnet, apply_firewalls: false)
    end

    fw9 = make_fw(location.id, project.id, "pre-commit-9")
    fw10 = make_fw(location.id, project.id, "post-commit-10")

    t1_attached = Queue.new
    t2_proceed = Queue.new
    t2_error = nil

    t1 = Thread.new do
      fw9.associate_with_private_subnet(subnet, apply_firewalls: false)
      t1_attached.push(true)
    end

    t1_attached.pop
    t1.join(5)
    expect(subnet.firewalls_dataset.count).to eq(9)

    t2 = Thread.new do
      t2_proceed.pop
      fw10.associate_with_private_subnet(subnet, apply_firewalls: false)
    rescue => e
      t2_error = e
    end

    t2_proceed.push(true)
    t2.join(5)

    expect(t2_error).to be_a(Validation::ValidationFailed)
    expect(t2_error.details[:firewall]).to match(/more than 9 firewalls/)
    expect(subnet.firewalls_dataset.count).to eq(9)
  end
end
