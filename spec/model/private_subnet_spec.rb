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

  it "allows inference endpoint ubid format as name" do
    ps = described_class.new(name: InferenceEndpoint.generate_ubid.to_s)
    ps.validate
    expect(ps.errors[:name]).to be_nil
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

  describe ".create_tunnels" do
    let(:src_nic) {
      instance_double(Nic, id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b")
    }
    let(:dst_nic) {
      instance_double(Nic, id: "6a187cc1-291b-8eac-bdfc-96801fa3118d")
    }

    it "creates tunnels if doesn't exist" do
      expect(IpsecTunnel).to receive(:create).with(src_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", dst_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d").and_return(true)
      expect(IpsecTunnel).to receive(:create).with(src_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d", dst_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b").and_return(true)
      private_subnet.create_tunnels([src_nic, dst_nic], dst_nic)
    end

    it "skips existing tunnels" do
      expect(IpsecTunnel).to receive(:[]).with(src_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", dst_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d").and_return(true)
      expect(IpsecTunnel).to receive(:[]).with(src_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d", dst_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b").and_return(false)

      expect(IpsecTunnel).to receive(:create).with(src_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d", dst_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b").and_return(true)
      private_subnet.create_tunnels([src_nic, dst_nic], dst_nic)
    end

    it "skips existing tunnels - 2" do
      expect(IpsecTunnel).to receive(:[]).with(src_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", dst_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d").and_return(false)
      expect(IpsecTunnel).to receive(:[]).with(src_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d", dst_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b").and_return(true)

      expect(IpsecTunnel).to receive(:create).with(src_nic_id: "8ce8a85c-c3d6-86ac-bfdf-022bad69440b", dst_nic_id: "6a187cc1-291b-8eac-bdfc-96801fa3118d").and_return(true)
      private_subnet.create_tunnels([src_nic, dst_nic], dst_nic)
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

  describe "connected subnets related methods" do
    let(:prj) {
      Project.create(name: "test-prj")
    }

    let(:ps1) {
      Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps1", location_id: Location::HETZNER_FSN1_ID).subject
    }

    it ".connected_subnets" do
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject
      expect(ps1.connected_subnets).to eq []

      ps1.connect_subnet(ps2)
      expect(ps1.connected_subnets.map(&:id)).to eq [ps2.id]
      expect(ps2.connected_subnets.map(&:id)).to eq [ps1.id]

      ps3 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps3", location_id: Location::HETZNER_FSN1_ID).subject
      ps2.connect_subnet(ps3)
      expect(ps1.connected_subnets.map(&:id)).to eq [ps2.id]
      expect(ps2.connected_subnets.map(&:id).sort).to eq [ps1.id, ps3.id].sort
      expect(ps3.connected_subnets.map(&:id)).to eq [ps2.id]

      ps1.disconnect_subnet(ps2)
      expect(ps1.connected_subnets.map(&:id)).to eq []
      expect(ps2.connected_subnets.map(&:id).sort).to eq [ps3.id].sort
      expect(ps3.connected_subnets.map(&:id)).to eq [ps2.id]
    end

    it ".all_nics" do
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject

      ps1_nic = Prog::Vnet::NicNexus.assemble(ps1.id, name: "test-ps1-nic1").subject
      ps2_nic = Prog::Vnet::NicNexus.assemble(ps2.id, name: "test-ps2-nic1").subject

      expect(ps1.all_nics.map(&:id)).to eq [ps1_nic.id]

      expect(ps1).to receive(:create_tunnels).with([ps2_nic], ps1_nic).and_call_original
      ps1.connect_subnet(ps2)

      expect(ps1.all_nics.map(&:id).sort).to eq [ps1_nic.id, ps2_nic.id].sort

      ps1.disconnect_subnet(ps2)

      expect(ps1.all_nics.map(&:id)).to eq [ps1_nic.id]
    end

    it "disconnect_subnet does not destroy in subnet tunnels" do
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps2", location_id: Location::HETZNER_FSN1_ID).subject
      ps1_nic = Prog::Vnet::NicNexus.assemble(ps1.id, name: "test-ps1-nic1").subject
      ps1_nic2 = Prog::Vnet::NicNexus.assemble(ps1.id, name: "test-ps1-nic2").subject
      ps1.create_tunnels([ps1_nic], ps1_nic2)

      ps2_nic = Prog::Vnet::NicNexus.assemble(ps2.id, name: "test-ps2-nic1").subject
      ps1.connect_subnet(ps2)
      expect(ps1.find_all_connected_nics.map(&:id).sort).to eq [ps1_nic.id, ps1_nic2.id, ps2_nic.id].sort
      expect(IpsecTunnel.count).to eq 6

      ps1.disconnect_subnet(ps2)
      expect(ps1.find_all_connected_nics.map(&:id).sort).to eq [ps1_nic.id, ps1_nic2.id].sort

      tunnels = ps1_nic.src_ipsec_tunnels + ps1_nic.dst_ipsec_tunnels
      expect(IpsecTunnel.all.map(&:id).sort).to eq(tunnels.map(&:id).sort)
      expect(IpsecTunnel.count).to eq 2
    end
  end
end
