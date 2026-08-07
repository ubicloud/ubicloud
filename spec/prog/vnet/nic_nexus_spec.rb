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
        name: "demonic", state: "initializing", is_management: false).and_return(nic)
      expect(Strand).to receive(:create_with_id).with(id, prog: "Vnet::Metal::NicNexus", label: "start", stack: [{"exclude_availability_zones" => [], "availability_zone" => nil, "ipv4_addr" => "10.0.0.12/32", "aws_subnet_id" => nil, "use_eip" => true}]).and_return(Strand.new)
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
        name: "demonic", state: "initializing", is_management: false).and_return(nic)
      expect(Strand).to receive(:create_with_id).with(id, prog: "Vnet::Metal::NicNexus", label: "start", stack: [{"exclude_availability_zones" => [], "availability_zone" => nil, "ipv4_addr" => "10.0.0.12/32", "aws_subnet_id" => nil, "use_eip" => true}]).and_return(Strand.new)
      described_class.assemble(ps.id, ipv4_addr: "10.0.0.12/32", name: "demonic")
    end

    context "when location is AWS" do
      let(:aws_project) { Project.create(name: "test-aws-assemble") }
      let(:aws_location) {
        location = Location.create(name: "us-west-2", provider: "aws", project_id: aws_project.id,
          display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
        LocationCredentialAws.create_with_id(location, access_key: "stubbed-akid", secret_key: "stubbed-secret")
        LocationAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
        location
      }
      let(:aws_ps) {
        Prog::Vnet::SubnetNexus.assemble(
          aws_project.id,
          name: "test-aws-ps",
          location_id: aws_location.id,
          ipv4_range: "10.0.0.0/16",
          ipv6_range: "fd10:1000::/64",
        ).subject
      }

      it "leaves address selection to AWS" do
        strand = described_class.assemble(aws_ps.id, name: "demonic")
        nic = strand.subject

        expect(nic).to have_attributes(name: "demonic", mac: nil, private_ipv4: nil, state: "creating")
        expect(nic.private_ipv6).not_to be_nil
        expect(strand).to have_attributes(prog: "Vnet::Aws::NicNexus", label: "start")
        expect(strand.stack.first["aws_subnet_id"]).to be_a(String)
      end

      it "preserves an explicit private IPv4 address" do
        strand = described_class.assemble(aws_ps.id, name: "demonic", ipv4_addr: "10.0.0.12/32")
        nic = strand.subject

        expect(nic.private_ipv4.to_s).to eq("10.0.0.12/32")
        expect(nic.state).to eq("active")
        expect(strand.stack.first["ipv4_addr"]).to eq("10.0.0.12/32")
      end
    end

    it "creates a GCP nic if location is gcp" do
      gcp_project = Project.create(name: "test-gcp-assemble")
      gcp_location = Location.create(name: "gcp-us-central1", provider: "gcp", project_id: gcp_project.id,
        display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
      gcp_ps = Prog::Vnet::SubnetNexus.assemble(gcp_project.id, name: "test-gcp-ps", location_id: gcp_location.id).subject

      strand = described_class.assemble(gcp_ps.id, name: "demonic")
      nic = strand.subject

      expect(nic.name).to eq("demonic")
      expect(nic.mac).to be_nil
      expect(nic.state).to eq("active")
      expect(nic.private_ipv4).not_to be_nil
      expect(nic.private_ipv6).not_to be_nil
      expect(strand.prog).to eq("Vnet::Gcp::NicNexus")
      expect(strand.label).to eq("start")
    end
  end

  describe ".select_aws_subnet" do
    let(:project) { Project.create(name: "test-aws-prj") }
    let(:aws_location) {
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
      LocationCredentialAws.create_with_id(loc.id, access_key: "stubbed-akid", secret_key: "stubbed-secret")
      loc
    }
    let(:az_a) { LocationAz.create(location_id: aws_location.id, az: "a", zone_id: "usw2-az1") }
    let(:az_b) { LocationAz.create(location_id: aws_location.id, az: "b", zone_id: "usw2-az2") }
    let(:aws_ps) {
      az_a
      aws_credentials = Aws::Credentials.new("stubbed-akid", "stubbed-secret")
      allow(Aws::Credentials).to receive(:new).with("stubbed-akid", "stubbed-secret").and_return(aws_credentials)
      allow(Aws::EC2::Client).to receive(:new).and_return(Aws::EC2::Client.new(stub_responses: true))
      Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-aws-ps", location_id: aws_location.id).subject
    }

    it "returns nil if no PrivateSubnetAwsResource" do
      result = described_class.select_aws_subnet(ps, nil, [])
      expect(result).to be_nil
    end

    it "returns a random subnet when no availability_zone specified" do
      aws_ps
      result = described_class.select_aws_subnet(aws_ps, nil, [])
      expect(result).to be_an(AwsSubnet)
    end

    it "returns preferred AZ subnet when availability_zone is specified" do
      az_b  # Create AZ b before assembling so assemble creates AwsSubnet for both AZs
      aws_ps
      result = described_class.select_aws_subnet(aws_ps, "b", [])
      expect(result.location_aws_az_id).to eq(az_b.id)
    end

    it "falls back to random subnet when preferred AZ has no LocationAz" do
      aws_ps
      result = described_class.select_aws_subnet(aws_ps, "z", [])
      expect(result).to be_an(AwsSubnet)
    end

    it "falls back to random subnet when preferred AZ exists but has no AwsSubnet" do
      aws_ps
      # Create AZ b AFTER assemble so no AwsSubnet record exists for it
      az_b
      result = described_class.select_aws_subnet(aws_ps, "b", [])
      expect(result).to be_an(AwsSubnet)
      expect(result.location_aws_az_id).to eq(az_a.id)
    end

    it "excludes specified availability zones" do
      az_b  # Create AZ b before assembling so assemble creates AwsSubnet for both AZs
      aws_ps
      result = described_class.select_aws_subnet(aws_ps, nil, ["a"])
      expect(result.location_aws_az_id).to eq(az_b.id)
    end

    it "falls back to any subnet when all availability zones are excluded" do
      aws_ps
      result = described_class.select_aws_subnet(aws_ps, nil, ["a"])
      expect(result).to be_an(AwsSubnet)
      expect(result.location_aws_az_id).to eq(az_a.id)
    end
  end
end
