# frozen_string_literal: true

RSpec.describe Prog::Vnet::NicNexus do
  let(:project) { Project.create(name: "test") }
  let(:ps) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26", state: "waiting", project_id: project.id)
  }

  def occupy_aws_subnet(private_subnet, aws_subnet, count)
    count.times do |index|
      nic = Nic.create(
        private_subnet_id: private_subnet.id,
        private_ipv4: "#{aws_subnet.ipv4_cidr.nth(index + 4)}/32",
        private_ipv6: "#{private_subnet.net6.nth(index + 2)}/128",
        name: "occupied-#{aws_subnet.az_suffix}-#{index}",
        state: "active",
      )
      NicAwsResource.create_with_id(nic, aws_subnet_id: aws_subnet.id)
    end
  end

  describe ".assemble" do
    it "fails if subnet doesn't exist" do
      expect {
        described_class.assemble("0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "uses ipv6_addr if passed" do
      strand = described_class.assemble(ps.id, ipv6_addr: "fd10:9b0b:6b4b:8fbb::/128", name: "demonic")
      nic = strand.subject

      expect(nic.private_ipv6.to_s).to eq("fd10:9b0b:6b4b:8fbb::/128")
      expect(nic.private_ipv4).not_to be_nil
      expect(nic.state).to eq("initializing")
      expect(strand).to have_attributes(prog: "Vnet::Metal::NicNexus", label: "start")
    end

    it "uses ipv4_addr if passed" do
      strand = described_class.assemble(ps.id, ipv4_addr: "10.0.0.12/32", name: "demonic")
      nic = strand.subject

      expect(nic.private_ipv4.to_s).to eq("10.0.0.12/32")
      expect(nic.private_ipv6).not_to be_nil
      expect(nic.state).to eq("initializing")
      expect(strand).to have_attributes(prog: "Vnet::Metal::NicNexus", label: "start")
    end

    context "when location is AWS" do
      let(:aws_project) { Project.create(name: "test-aws-assemble") }
      let(:aws_location) {
        loc = Location.create(name: "us-west-2", provider: "aws", project_id: aws_project.id, display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
        LocationCredentialAws.create_with_id(loc, access_key: "stubbed-akid", secret_key: "stubbed-secret")
        LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
        loc
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

      it "assembles an AWS NIC with an allocated IPv4 by default" do
        strand = described_class.assemble(aws_ps.id, name: "demonic")
        nic = strand.subject

        expect(nic.name).to eq("demonic")
        expect(nic.mac).to be_nil
        expect(nic.state).to eq("active")
        expect(nic.private_ipv4).not_to be_nil
        expect(nic.private_ipv6).not_to be_nil
        expect(strand).to have_attributes(prog: "Vnet::Aws::NicNexus", label: "start")
        expect(strand.stack.first["aws_subnet_id"]).not_to be_nil
      end

      it "lets AWS assign IPv4 for a no-EIP NIC" do
        strand = described_class.assemble(aws_ps.id, name: "demonic", use_eip: false)
        nic = strand.subject

        expect(nic.private_ipv4).to be_nil
        expect(nic.private_ipv4_address).to be_nil
        expect(nic.state).to eq("creating")
        expect(strand.stack.first["aws_subnet_id"]).to be_a(String)
        expect(strand.stack.first).to include("ipv4_addr" => nil, "use_eip" => false)
      end

      it "keeps an explicit IPv4 for a no-EIP NIC" do
        strand = described_class.assemble(
          aws_ps.id,
          name: "demonic",
          ipv4_addr: "10.0.0.12/32",
          use_eip: false,
        )
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
    let(:project) { Project.create(name: "test-aws-select-prj") }
    let(:aws_location) {
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
      LocationCredentialAws.create_with_id(loc, access_key: "stubbed-akid", secret_key: "stubbed-secret")
      loc
    }
    let(:az_a) { LocationAz.create(location_id: aws_location.id, az: "a", zone_id: "usw2-az1") }
    let(:az_b) { LocationAz.create(location_id: aws_location.id, az: "b", zone_id: "usw2-az2") }
    let(:az_c) { LocationAz.create(location_id: aws_location.id, az: "c", zone_id: "usw2-az3") }
    let(:aws_ps) {
      az_a
      az_b
      Prog::Vnet::SubnetNexus.assemble(
        project.id,
        name: "test-aws-select-ps",
        location_id: aws_location.id,
        ipv4_range: "10.0.0.0/27",
        ipv6_range: "fd10:2000::/64",
        aws_subnet_ipv4_range_size: 28,
      ).subject
    }
    let(:aws_subnet_a) {
      AwsSubnet[
        private_subnet_aws_resource_id: aws_ps.private_subnet_aws_resource.id,
        location_aws_az_id: az_a.id,
      ]
    }
    let(:aws_subnet_b) {
      AwsSubnet[
        private_subnet_aws_resource_id: aws_ps.private_subnet_aws_resource.id,
        location_aws_az_id: az_b.id,
      ]
    }

    it "returns nil if no PrivateSubnetAwsResource" do
      result = described_class.select_aws_subnet(ps, nil, [])
      expect(result).to be_nil
    end

    it "returns an AWS subnet when no availability zone is specified" do
      result = described_class.select_aws_subnet(aws_ps, nil, [])
      expect([aws_subnet_a.id, aws_subnet_b.id]).to include(result.id)
    end

    it "returns preferred AZ subnet when availability_zone is specified" do
      result = described_class.select_aws_subnet(aws_ps, "b", [])
      expect(result.id).to eq(aws_subnet_b.id)
    end

    it "does not return an excluded preferred AZ" do
      result = described_class.select_aws_subnet(aws_ps, "b", ["b"])
      expect(result.id).to eq(aws_subnet_a.id)
    end

    it "falls back when the preferred AZ has no LocationAz" do
      result = described_class.select_aws_subnet(aws_ps, "z", [])
      expect([aws_subnet_a.id, aws_subnet_b.id]).to include(result.id)
    end

    it "falls back when the preferred AZ has no AwsSubnet" do
      existing_subnet_ids = [aws_subnet_a.id, aws_subnet_b.id]
      az_c
      result = described_class.select_aws_subnet(aws_ps, "c", [])
      expect(existing_subnet_ids).to include(result.id)
    end

    it "excludes specified availability zones" do
      result = described_class.select_aws_subnet(aws_ps, nil, ["a"])
      expect(result.id).to eq(aws_subnet_b.id)
    end

    it "falls back to any subnet when all availability zones are excluded" do
      result = described_class.select_aws_subnet(aws_ps, nil, ["a", "b"])
      expect([aws_subnet_a.id, aws_subnet_b.id]).to include(result.id)
    end

    it "falls back when the preferred AZ has no IPv4 capacity" do
      occupy_aws_subnet(aws_ps, aws_subnet_b, aws_subnet_b.available_ipv4_count)

      result = described_class.select_aws_subnet(aws_ps, "b", [])
      expect(result.id).to eq(aws_subnet_a.id)
    end

    it "selects the subnet with the most IPv4 capacity" do
      occupy_aws_subnet(aws_ps, aws_subnet_a, 1)

      result = described_class.select_aws_subnet(aws_ps, nil, [])
      expect(result.id).to eq(aws_subnet_b.id)
    end
  end

  describe ".allocate_ipv4_from_aws_subnet" do
    let(:project) { Project.create(name: "test-alloc-prj") }
    let(:aws_location) {
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
      LocationCredentialAws.create_with_id(loc, access_key: "stubbed-akid", secret_key: "stubbed-secret")
      loc
    }
    let(:az_a) { LocationAz.create(location_id: aws_location.id, az: "a", zone_id: "usw2-az1") }
    let(:aws_ps) {
      az_a
      Prog::Vnet::SubnetNexus.assemble(
        project.id,
        name: "test-alloc-ps",
        location_id: aws_location.id,
        ipv4_range: "10.0.0.0/16",
        ipv6_range: "fd10:3000::/64",
      ).subject
    }

    it "returns random_private_ipv4 if aws_subnet is nil" do
      result = described_class.allocate_ipv4_from_aws_subnet(aws_ps, nil)
      expect(result).to be_a(NetAddr::IPv4Net)
      expect(aws_ps.net4.rel(result)).to eq(1)
    end

    it "allocates IP from AWS subnet CIDR" do
      aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: aws_ps.private_subnet_aws_resource.id).first
      result = described_class.allocate_ipv4_from_aws_subnet(aws_ps, aws_subnet)
      allocated = NetAddr::IPv4Net.parse(result)

      expect(allocated.netmask.prefix_len).to eq(32)
      expect(aws_subnet.ipv4_cidr.rel(allocated)).to eq(1)
    end

    it "ignores NICs whose IPv4 address AWS has not assigned yet" do
      pending_nic = described_class.assemble(aws_ps.id, name: "pending-nic", use_eip: false).subject
      aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: aws_ps.private_subnet_aws_resource.id).first

      result = described_class.allocate_ipv4_from_aws_subnet(aws_ps, aws_subnet)
      allocated = NetAddr::IPv4Net.parse(result)

      expect(pending_nic.private_ipv4).to be_nil
      expect(allocated.netmask.prefix_len).to eq(32)
      expect(aws_subnet.ipv4_cidr.rel(allocated)).to eq(1)
    end

    it "skips IPs already in use by existing NICs" do
      aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: aws_ps.private_subnet_aws_resource.id).first
      nic = described_class.assemble(aws_ps.id, name: "existing-nic").subject
      existing_ip = nic.private_ipv4.network.to_s

      subnet_cidr = NetAddr::IPv4Net.parse(aws_subnet.ipv4_cidr.to_s)
      total_hosts = 2**(32 - subnet_cidr.netmask.prefix_len) - 5
      existing_ip_int = NetAddr::IPv4.parse(existing_ip).addr
      subnet_start_int = subnet_cidr.network.addr
      existing_offset = existing_ip_int - subnet_start_int - 4
      free_offset = (existing_offset + 1) % total_hosts
      expect(SecureRandom).to receive(:random_number).with(total_hosts).and_return(existing_offset, free_offset)

      result = described_class.allocate_ipv4_from_aws_subnet(aws_ps, aws_subnet)
      expect(result).to eq("#{subnet_cidr.nth(free_offset + 4)}/32")
    end
  end
end
