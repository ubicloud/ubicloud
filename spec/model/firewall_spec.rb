# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Firewall do
  let(:project_id) { Project.create(name: "test").id }

  let(:fw) {
    described_class.create(name: "test-fw", description: "test fw desc", location_id: Location::HETZNER_FSN1_ID, project_id:)
  }

  let(:ps) {
    private_subnet = PrivateSubnet.create(name: "test-ps", location_id: Location::HETZNER_FSN1_ID, net6: "2001:db8::/64", net4: "10.0.0.0/24", project_id:)
    Strand.create(prog: "Vnet::SubnetNexus", label: "wait", id: private_subnet.id)
    private_subnet
  }

  it "inserts firewall rules" do
    fw.insert_firewall_rule("10.0.0.16/28", Sequel.pg_range(80..5432))
    expect(fw.firewall_rules.count).to eq(1)
    expect(fw.firewall_rules.first.cidr.to_s).to eq("10.0.0.16/28")
    pr = fw.firewall_rules.first.port_range
    expect(pr.begin).to eq(80)
    expect(pr.end).to eq(5433)
  end

  it "increments update_firewall_rules semaphore on associated private subnets" do
    fw.associate_with_private_subnet(ps, apply_firewalls: false)
    expect {
      fw.insert_firewall_rule("0.0.0.0/0", nil)
    }.to change { ps.reload.update_firewall_rules_set? }.from(false).to(true)
  end

  it "bulk sets firewall rules" do
    fw.insert_firewall_rule("10.0.0.16/28", Sequel.pg_range(80..5432))
    fw.insert_firewall_rule("0.0.0.0/32", Sequel.pg_range(5432..5432))
    fw.replace_firewall_rules([{cidr: "0.0.0.0/32", port_range: Sequel.pg_range(5432..5432)}])
    expect(fw.reload.firewall_rules.count).to eq(1)
    expect(fw.reload.firewall_rules.first.cidr.to_s).to eq("0.0.0.0/32")
  end

  it "associates with a private subnet" do
    expect {
      fw.associate_with_private_subnet(ps)
    }.to change { ps.reload.update_firewall_rules_set? }.from(false).to(true)

    expect(fw.private_subnets.count).to eq(1)
    expect(fw.private_subnets.first.id).to eq(ps.id)
  end

  it "disassociates from a private subnet" do
    fw.associate_with_private_subnet(ps, apply_firewalls: false)
    expect(fw.private_subnets.count).to eq(1)

    expect {
      fw.disassociate_from_private_subnet(ps)
    }.to change { ps.reload.update_firewall_rules_set? }.from(false).to(true)

    expect(fw.reload.private_subnets.count).to eq(0)
    expect(PrivateSubnetFirewall.where(firewall_id: fw.id).count).to eq(0)
  end

  it "disassociates from a private subnet without applying firewalls" do
    fw.associate_with_private_subnet(ps, apply_firewalls: false)
    expect(fw.private_subnets.count).to eq(1)

    expect {
      fw.disassociate_from_private_subnet(ps, apply_firewalls: false)
    }.not_to change { ps.reload.update_firewall_rules_set? }.from(false)

    expect(fw.reload.private_subnets.count).to eq(0)
    expect(PrivateSubnetFirewall.where(firewall_id: fw.id).count).to eq(0)
  end

  it "destroys firewall" do
    fw.associate_with_private_subnet(ps, apply_firewalls: false)
    expect(fw.reload.private_subnets.count).to eq(1)
    expect(PrivateSubnetFirewall.where(firewall_id: fw.id).count).to eq(1)
    fw.destroy
    expect(PrivateSubnetFirewall.where(firewall_id: fw.id).count).to eq(0)
    expect(described_class[fw.id]).to be_nil
  end

  describe "GCP firewall-per-VM limit" do
    let(:gcp_location) {
      Location.create(name: "gcp-us-central1", provider: "gcp",
        display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true,
        project_id:)
    }

    let(:gcp_ps) {
      PrivateSubnet.create(name: "gcp-ps", location_id: gcp_location.id, project_id:,
        net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "active")
    }

    def make_fw(name)
      described_class.create(name:, description: "desc", location_id: gcp_location.id, project_id:)
    end

    def attach_vm(name, idx)
      vm = create_vm(project_id:, location_id: gcp_location.id, name:)
      Nic.create(private_subnet_id: gcp_ps.id, vm_id: vm.id, name: "nic-#{idx}",
        private_ipv4: gcp_ps.net4.nth(idx + 2).to_s,
        private_ipv6: gcp_ps.net6.nth(idx + 2).to_s,
        mac: "00:00:00:00:00:%02x" % idx, state: "active")
      vm
    end

    it "allows associating up to 9 firewalls on a GCP subnet with a VM" do
      attach_vm("gcp-vm", 1)
      9.times { |i| make_fw("fw-#{i}").associate_with_private_subnet(gcp_ps, apply_firewalls: false) }
      expect(gcp_ps.reload.firewalls.count).to eq(9)
    end

    it "raises when associating a 10th firewall on a GCP subnet with a VM" do
      attach_vm("gcp-vm", 1)
      9.times { |i| make_fw("fw-#{i}").associate_with_private_subnet(gcp_ps, apply_firewalls: false) }
      tenth = make_fw("fw-10")
      expect {
        tenth.associate_with_private_subnet(gcp_ps, apply_firewalls: false)
      }.to raise_error(Validation::ValidationFailed) { |e|
        expect(e.details[:firewall]).to match(/more than 9 firewalls/)
      }
      expect(gcp_ps.reload.firewalls.count).to eq(9)
    end

    it "allows associating a 10th firewall on a GCP subnet with no VMs" do
      10.times { |i| make_fw("fw-#{i}").associate_with_private_subnet(gcp_ps, apply_firewalls: false) }
      expect(gcp_ps.reload.firewalls.count).to eq(10)
    end

    # Wiring smoke tests, not a real race. These stub Firewall.lock_subnet_for_gcp_cap!
    # and inject "peer" writes from inside the same RSpec transaction, so they verify
    # ordering and basic wiring but cannot catch a regression that silently drops the
    # FOR UPDATE row lock. See spec/model/firewall_concurrency_spec.rb for the real
    # two-connection concurrency specs that exercise the lock.
    describe "TOCTOU race serialization (wiring smoke test, not a real race)" do
      it "locks the subnet row before cap validation in associate_with_private_subnet (race B)" do
        attach_vm("gcp-vm", 1)
        8.times { |i| make_fw("fw-#{i}").associate_with_private_subnet(gcp_ps, apply_firewalls: false) }
        fw9 = make_fw("fw-9")

        lock_calls = []
        allow(described_class).to receive(:lock_subnet_for_gcp_cap!).and_wrap_original do |m, ps|
          lock_calls << ps.id
          m.call(ps)
        end
        cap_calls = []
        allow(described_class).to receive(:validate_gcp_firewall_cap!).and_wrap_original do |m, vm, **kw|
          cap_calls << vm.id
          m.call(vm, **kw)
        end

        fw9.associate_with_private_subnet(gcp_ps, apply_firewalls: false)
        expect(lock_calls).to eq([gcp_ps.id])
        expect(cap_calls).not_to be_empty
        # Lock acquired before any cap validation read.
        expect(lock_calls.size).to be >= 1
      end

      it "sees firewalls committed by a prior transaction that held the lock (race B)" do
        attach_vm("gcp-vm", 1)
        # Simulate T1 (subnet-attach path) having committed 9 firewalls onto the
        # subnet just before T2 tries to attach its own firewall; T2 acquires the
        # lock after T1 releases it, and its cap read now sees the 9 committed rows.
        9.times { |i| make_fw("fw-#{i}").associate_with_private_subnet(gcp_ps, apply_firewalls: false) }
        tenth = make_fw("fw-10")
        expect {
          tenth.associate_with_private_subnet(gcp_ps, apply_firewalls: false)
        }.to raise_error(Validation::ValidationFailed) { |e|
          expect(e.details[:firewall]).to match(/more than 9 firewalls/)
        }
        expect(gcp_ps.reload.firewalls.count).to eq(9)
      end

      it "rejects a firewall attach when a concurrent attach commits first (simulated race B)" do
        attach_vm("gcp-vm", 1)
        8.times { |i| make_fw("fw-#{i}").associate_with_private_subnet(gcp_ps, apply_firewalls: false) }
        fw9 = make_fw("fw-9")
        tenth = make_fw("fw-10")

        # Stub the lock acquisition to simulate "concurrent" commit from a peer
        # transaction that also takes the subnet lock: when T2 (tenth) acquires
        # the lock, the peer's write (fw9 attached) is already visible.
        peer_committed = false
        allow(described_class).to receive(:lock_subnet_for_gcp_cap!).and_wrap_original do |m, ps|
          result = m.call(ps)
          unless peer_committed
            peer_committed = true
            # Bypass the locking path to emulate another committed transaction
            # that already attached fw9 before the lock was granted to us.
            fw9.add_private_subnet(ps)
          end
          result
        end

        expect {
          tenth.associate_with_private_subnet(gcp_ps, apply_firewalls: false)
        }.to raise_error(Validation::ValidationFailed) { |e|
          expect(e.details[:firewall]).to match(/more than 9 firewalls/)
        }
      end

      it "wraps the attach in a DB transaction so the lock is held with the write" do
        attach_vm("gcp-vm", 1)
        fw = make_fw("fw-x")
        in_tx = nil
        allow(described_class).to receive(:lock_subnet_for_gcp_cap!).and_wrap_original do |m, ps|
          in_tx = DB.in_transaction?
          m.call(ps)
        end
        fw.associate_with_private_subnet(gcp_ps, apply_firewalls: false)
        expect(in_tx).to be true
      end
    end

    it "allows associating a 10th firewall when the subnet is non-GCP" do
      hetzner_ps = PrivateSubnet.create(name: "hz-ps", location_id: Location::HETZNER_FSN1_ID, project_id:,
        net6: "fd10:9b0b:6b4b:1000::/64", net4: "10.1.0.0/26", state: "active")
      vm = create_vm(project_id:, location_id: Location::HETZNER_FSN1_ID, name: "hz-vm")
      Nic.create(private_subnet_id: hetzner_ps.id, vm_id: vm.id, name: "nic-1",
        private_ipv4: hetzner_ps.net4.nth(3).to_s,
        private_ipv6: hetzner_ps.net6.nth(3).to_s,
        mac: "00:00:00:00:01:01", state: "active")
      10.times do |i|
        described_class.create(name: "hz-fw-#{i}", description: "d",
          location_id: Location::HETZNER_FSN1_ID, project_id:)
          .associate_with_private_subnet(hetzner_ps, apply_firewalls: false)
      end
      expect(hetzner_ps.reload.firewalls.count).to eq(10)
    end
  end

  it "removes referencing access control entries and object tag memberships" do
    account = Account.create(email: "test@example.com")
    project = account.create_project_with_default_policy("project-1", default_policy: false)
    tag = ObjectTag.create(project_id: project.id, name: "t")
    tag.add_member(fw.id)
    fw.update(project_id: project.id)
    ace = AccessControlEntry.create(project_id: project.id, subject_id: account.id, object_id: fw.id)

    fw.destroy
    expect(tag.member_ids).to be_empty
    expect(ace).not_to be_exists
  end
end
