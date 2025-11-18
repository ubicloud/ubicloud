# frozen_string_literal: true

RSpec.describe Prog::Vnet::NicNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:ps) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26", state: "waiting", project_id: Project.create(name: "test").id).tap { it.id = "57afa8a7-2357-4012-9632-07fbe13a3133" }
  }

  describe ".assemble" do
    it "fails if subnet doesn't exist" do
      expect {
        described_class.assemble("0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "uses ipv6_addr if passed" do
      expect(PrivateSubnet).to receive(:[]).with("57afa8a7-2357-4012-9632-07fbe13a3133").and_return(ps)
      expect(ps).to receive(:random_private_ipv4).and_return("10.0.0.12/32")
      expect(ps).not_to receive(:random_private_ipv6)
      expect(described_class).to receive(:rand).and_return(123).exactly(6).times
      id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
      expect(Nic).to receive(:generate_ubid).and_return(UBID.from_uuidish(id))
      nic = instance_double(Nic, private_subnet: ps, id:)
      expect(Nic).to receive(:create_with_id).with(id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.12/32",
        mac: "7a:7b:7b:7b:7b:7b",
        private_subnet_id: "57afa8a7-2357-4012-9632-07fbe13a3133",
        name: "demonic", state: "initializing").and_return(nic)
      expect(Strand).to receive(:create_with_id).with(id, prog: "Vnet::Metal::NicNexus", label: "start", stack: [{"exclude_availability_zones" => [], "availability_zone" => nil, "ipv4_addr" => "10.0.0.12/32"}]).and_return(Strand.new)
      described_class.assemble(ps.id, ipv6_addr: "fd10:9b0b:6b4b:8fbb::/128", name: "demonic")
    end

    it "uses ipv4_addr if passed" do
      expect(PrivateSubnet).to receive(:[]).with("57afa8a7-2357-4012-9632-07fbe13a3133").and_return(ps)
      expect(ps).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/128")
      expect(ps).not_to receive(:random_private_ipv4)
      id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
      expect(described_class).to receive(:gen_mac).and_return("00:11:22:33:44:55")
      expect(Nic).to receive(:generate_ubid).and_return(UBID.from_uuidish(id))
      nic = instance_double(Nic, private_subnet: ps, id:)
      expect(Nic).to receive(:create_with_id).with(id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.12/32",
        mac: "00:11:22:33:44:55",
        private_subnet_id: "57afa8a7-2357-4012-9632-07fbe13a3133",
        name: "demonic", state: "initializing").and_return(nic)
      expect(Strand).to receive(:create_with_id).with(id, prog: "Vnet::Metal::NicNexus", label: "start", stack: [{"exclude_availability_zones" => [], "availability_zone" => nil, "ipv4_addr" => "10.0.0.12/32"}]).and_return(Strand.new)
      described_class.assemble(ps.id, ipv4_addr: "10.0.0.12/32", name: "demonic")
    end

    it "hops to create_aws_nic if location is aws" do
      expect(ps).to receive(:location).and_return(instance_double(Location, aws?: true)).at_least(:once)
      expect(PrivateSubnet).to receive(:[]).with("57afa8a7-2357-4012-9632-07fbe13a3133").and_return(ps).at_least(:once)
      expect(ps).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/128")
      expect(ps).to receive(:random_private_ipv4).and_return(NetAddr::IPv4Net.parse("10.0.0.0/26"))
      id = "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
      expect(Nic).to receive(:generate_ubid).and_return(UBID.from_uuidish(id))
      nic = instance_double(Nic, private_subnet: ps, id:)
      expect(Nic).to receive(:create_with_id).with(id,
        private_ipv6: "fd10:9b0b:6b4b:8fbb::/128",
        private_ipv4: "10.0.0.4/32",
        mac: nil,
        private_subnet_id: "57afa8a7-2357-4012-9632-07fbe13a3133",
        name: "demonic", state: "active").and_return(nic)
      expect(Strand).to receive(:create_with_id).with(id, prog: "Vnet::Aws::NicNexus", label: "start", stack: [{"exclude_availability_zones" => [], "availability_zone" => nil, "ipv4_addr" => "10.0.0.4/32"}]).and_return(Strand.new)
      described_class.assemble(ps.id, name: "demonic")
    end
  end
end
