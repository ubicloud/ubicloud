# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PrivateSubnet do
  subject(:private_subnet) {
    described_class.new(
      net6: NetAddr.parse_net("fd1b:9793:dcef:cd0a::/64"),
      net4: NetAddr.parse_net("10.9.39.0/26"),
      location_id: Location::HETZNER_FSN1_ID,
      state: "waiting",
      name: "ps",
      project_id: Project.create(name: "test").id
    )
  }

  let(:nic) { instance_double(Nic, id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e") }
  let(:existing_nic) {
    instance_double(Nic,
      id: "46ca6ded-b056-4723-bd91-612959f52f6f",
      private_ipv4: "10.9.39.5/32",
      private_ipv6: "fd1b:9793:dcef:cd0a:c::/79")
  }

  it "disallows VM ubid format as name" do
    ps = described_class.new(name: described_class.generate_ubid.to_s)
    ps.validate
    expect(ps.errors[:name]).to eq ["cannot be exactly 26 numbers/lowercase characters starting with ps to avoid overlap with id format"]
  end

  describe "random ip generation" do
    it "returns random private ipv4" do
      private_subnet
      expect(SecureRandom).to receive(:random_number).with(59).and_return(5)
      expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.9/32"
    end

    it "returns random private ipv6" do
      private_subnet
      expect(SecureRandom).to receive(:random_number).with(32766).and_return(5)
      expect(private_subnet.random_private_ipv6.to_s).to eq "fd1b:9793:dcef:cd0a:c::/79"
    end

    it "returns random private ipv4 when ip exists" do
      private_subnet
      expect(SecureRandom).to receive(:random_number).with(59).and_return(1, 2)
      expect(private_subnet).to receive(:nics).and_return([existing_nic]).twice
      expect(private_subnet.random_private_ipv4.to_s).to eq "10.9.39.6/32"
    end

    it "returns random private ipv6 when ip exists" do
      private_subnet
      expect(SecureRandom).to receive(:random_number).with(32766).and_return(5, 6)
      expect(private_subnet).to receive(:nics).and_return([existing_nic]).twice
      expect(private_subnet.random_private_ipv6.to_s).to eq "fd1b:9793:dcef:cd0a:e::/79"
    end
  end

  describe ".[]" do
    let(:private_subnet) {
      subnet = super()
      subnet.net6 = subnet.net6.to_s
      subnet.net4 = subnet.net4.to_s
      subnet.id = described_class.generate_ubid.to_uuid.to_s
      subnet.save_changes
    }

    it "looks up by ubid object" do
      expect(described_class[UBID.parse(private_subnet.ubid)].id).to eq private_subnet.id
    end

    it "looks up by ubid string" do
      expect(described_class[private_subnet.ubid].id).to eq private_subnet.id
    end

    it "looks up by uuid string" do
      expect(described_class[private_subnet.id].id).to eq private_subnet.id
    end

    it "looks up by hash" do
      expect(described_class[id: private_subnet.id].id).to eq private_subnet.id
    end

    it "doesn't raise if given something that looks like a ubid but isn't" do
      expect(described_class["a" * 26]).to be_nil
    end
  end

  describe "#inspect" do
    it "includes ubid if id is available" do
      ubid = described_class.generate_ubid
      private_subnet.id = ubid.to_uuid.to_s
      expect(private_subnet.inspect).to eq "#<PrivateSubnet[\"#{ubid}\"] @values={net6: \"fd1b:9793:dcef:cd0a::/64\", net4: \"10.9.39.0/26\", location_id: \"10saktg1sprp3mxefj1m3kppq2\", state: \"waiting\", name: \"ps\", project_id: \"#{private_subnet.project.ubid}\"}>"
    end

    it "does not includes ubid if id is missing" do
      expect(private_subnet.inspect).to eq "#<PrivateSubnet @values={net6: \"fd1b:9793:dcef:cd0a::/64\", net4: \"10.9.39.0/26\", location_id: \"10saktg1sprp3mxefj1m3kppq2\", state: \"waiting\", name: \"ps\", project_id: \"#{private_subnet.project.ubid}\"}>"
    end
  end

  describe "uuid to name" do
    it "returns the name" do
      expect(described_class.ubid_to_name("psetv2ff83xj6h3prt2jwavh0q")).to eq "psetv2ff"
    end
  end

  describe "ui utility methods" do
    it "returns path" do
      expect(private_subnet.path).to eq "/location/eu-central-h1/private-subnet/ps"
    end
  end

  describe "display_state" do
    it "returns available when waiting" do
      expect(private_subnet.display_state).to eq "available"
    end

    it "returns state if not waiting" do
      private_subnet.state = "failed"
      expect(private_subnet.display_state).to eq "failed"
    end
  end

  describe "destroy" do
    it "destroys firewalls private subnets" do
      project_id = Project.create(name: "test").id
      ps = described_class.create(name: "test-ps", location_id: Location::HETZNER_FSN1_ID, net6: "2001:db8::/64", net4: "10.0.0.0/24", project_id:)
      ps.add_firewall(project_id:, location_id: Location::HETZNER_FSN1_ID)
      expect(ps.firewalls_dataset.count).to eq 1
      ps.destroy
      expect(ps.firewalls_dataset.count).to eq 0
    end
  end

  describe "incr_destroy_if_only_used_internally" do
    let(:prj) { Project.create(name: "test-prj") }

    let(:ps) { Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps1", location_id: Location::HETZNER_FSN1_ID).subject }

    it "destroys associated firewalls in any project if name matches and firewall is not related to other subnets" do
      ubid = described_class.generate_ubid
      ps.firewalls.first.update(name: "#{ubid}-firewall")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.firewalls_dataset.all).to be_empty
    end

    it "does not destroy associated firewalls if name does match" do
      ps.incr_destroy_if_only_used_internally(
        ubid: described_class.generate_ubid,
        vm_ids: []
      )
      expect(ps.firewalls_dataset.count).to eq 1
    end

    it "does not destroy associated firewalls associated to other private subnets" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject
      fw.associate_with_private_subnet(ps2)

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.firewalls_dataset.count).to eq 1
    end

    it "incr_destroys private subnet if name matches, and it does not have any firewalls or vms" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_order_map(:name)).to eq ["destroy", "update_firewall_rules"]
    end

    it "incr_destroys private subnet if name matches, and it does not have any firewalls or vms other the ones given in vm_ids" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      vm = Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id).subject

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: [vm.id]
      )
      expect(ps.semaphores_dataset.select_order_map(:name)).to eq ["destroy", "update_firewall_rules"]
    end

    it "does not incr_destroy private subnet if name does not match" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet2")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq ["update_firewall_rules"]
    end

    it "does not incr_destroy private subnet if firewalls remain" do
      ubid = described_class.generate_ubid
      ps.update(name: "#{ubid}-subnet")

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq []
    end

    it "does not incr_destroy private subnet if it contains vms not listed in vm_ids" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id)

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq ["update_firewall_rules"]
    end

    it "incr_destroys private subnet if it only contains nics with nil vm_id" do
      ubid = described_class.generate_ubid
      fw = ps.firewalls.first
      fw.update(name: "#{ubid}-firewall")
      ps.update(name: "#{ubid}-subnet")
      vm = Prog::Vm::Nexus.assemble("some_ssh key", prj.id, private_subnet_id: ps.id).subject
      vm.nic.update(vm_id: nil)

      ps.incr_destroy_if_only_used_internally(
        ubid:,
        vm_ids: []
      )
      expect(ps.semaphores_dataset.select_map(:name)).to eq ["update_firewall_rules", "destroy"]
    end
  end
end
