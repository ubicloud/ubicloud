# frozen_string_literal: true

RSpec.describe Prog::Vnet::Aws::BackfillAwsSubnets do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-prj") }
  let(:location) {
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
    LocationCredential.create_with_id(loc.id, access_key: "stubbed-akid", secret_key: "stubbed-secret")
    loc
  }
  let(:az_a) { LocationAwsAz.create(location_id: location.id, az: "a", zone_id: "usw2-az1") }
  let(:az_b) { LocationAwsAz.create(location_id: location.id, az: "b", zone_id: "usw2-az2") }
  let(:az_c) { LocationAwsAz.create(location_id: location.id, az: "c", zone_id: "usw2-az3") }

  let(:client) { Aws::EC2::Client.new(stub_responses: true) }

  before do
    az_a
    aws_credentials = Aws::Credentials.new("stubbed-akid", "stubbed-secret")
    allow(Aws::Credentials).to receive(:new).with("stubbed-akid", "stubbed-secret").and_return(aws_credentials)
    allow(Aws::EC2::Client).to receive(:new).with(credentials: aws_credentials, region: "us-west-2").and_return(client)
  end

  describe "#assemble" do
    it "fails if private subnet does not exist" do
      expect {
        described_class.assemble("00000000-0000-0000-0000-000000000000")
      }.to raise_error("No existing private subnet")
    end

    it "fails if private subnet is not AWS" do
      metal_loc = Location.create(name: "hetzner-fsn1", provider: "hetzner", project_id: project.id, display_name: "hetzner-fsn1", ui_name: "Hetzner FSN1", visible: true)
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-metal", location_id: metal_loc.id).subject
      expect {
        described_class.assemble(ps.id)
      }.to raise_error("Private subnet is not in an AWS location")
    end

    it "fails if no PrivateSubnetAwsResource exists" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject
      ps.private_subnet_aws_resource.aws_subnets.each(&:destroy)
      ps.private_subnet_aws_resource.destroy
      expect {
        described_class.assemble(ps.id)
      }.to raise_error("Private subnet has no AWS resource")
    end

    it "fails if no vpc_id is set" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject
      ps.private_subnet_aws_resource.aws_subnets.each(&:destroy)
      expect {
        described_class.assemble(ps.id)
      }.to raise_error("Private subnet AWS resource has no VPC ID")
    end

    it "fails if AwsSubnet records already exist" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject
      ps.private_subnet_aws_resource.update(vpc_id: "vpc-123")
      expect {
        described_class.assemble(ps.id)
      }.to raise_error("Private subnet already has AwsSubnet records")
    end

    it "creates a strand" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject
      ps.private_subnet_aws_resource.update(vpc_id: "vpc-123")
      ps.private_subnet_aws_resource.aws_subnets.each(&:destroy)
      st = described_class.assemble(ps.id)
      expect(st).to be_a(Strand)
      expect(st.prog).to eq("Vnet::Aws::BackfillAwsSubnets")
      expect(st.label).to eq("start")
      expect(st.stack.first["subject_id"]).to eq(ps.id)
    end
  end

  describe "old /26 VPCs" do
    let(:ps) {
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-old-ps", location_id: location.id).subject
      # Simulate old /26 format
      ps.update(net4: "10.0.0.0/26")
      ps.private_subnet_aws_resource.update(
        vpc_id: "vpc-old",
        route_table_id: "rtb-old",
        security_group_id: "sg-old",
        internet_gateway_id: "igw-old"
      )
      # Remove AwsSubnet records created by assemble to simulate pre-migration state
      ps.private_subnet_aws_resource.aws_subnets.each(&:destroy)
      ps
    }

    let(:st) {
      Strand.create(prog: "Vnet::Aws::BackfillAwsSubnets", label: "start", stack: [{"subject_id" => ps.id}])
    }

    let(:nic) {
      nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-old-nic").subject
      NicAwsResource.create_with_id(nic.id, subnet_id: "subnet-old", subnet_az: "us-west-2a")
      nic
    }

    describe "#start" do
      it "hops to backfill_old_subnet for /26 VPCs" do
        expect { nx.start }.to hop("backfill_old_subnet")
      end
    end

    describe "#backfill_old_subnet" do
      before do
        st.update(label: "backfill_old_subnet")
        nic
      end

      it "creates AwsSubnet record for existing subnet" do
        client.stub_responses(:describe_subnets, subnets: [{
          subnet_id: "subnet-old",
          cidr_block: "10.0.0.0/26",
          availability_zone: "us-west-2a",
          ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14::/64"}]
        }])

        expect { nx.backfill_old_subnet }.to hop("link_nics")
        aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id).first
        expect(aws_subnet.subnet_id).to eq("subnet-old")
        expect(aws_subnet.ipv4_cidr.to_s).to eq("10.0.0.0/26")
        expect(aws_subnet.ipv6_cidr.to_s).to eq("2600:1f14::/64")
        expect(aws_subnet.location_aws_az_id).to eq(az_a.id)
      end

      it "fails if no subnets found in VPC" do
        client.stub_responses(:describe_subnets, subnets: [])
        expect { nx.backfill_old_subnet }.to raise_error("No subnets found in VPC vpc-old")
      end

      it "fetches AZs from AWS if LocationAwsAz not cached" do
        # Remove the existing AZ record
        LocationAwsAz.where(id: az_a.id).destroy

        client.stub_responses(:describe_subnets, subnets: [{
          subnet_id: "subnet-old",
          cidr_block: "10.0.0.0/26",
          availability_zone: "us-west-2a",
          ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14::/64"}]
        }])
        client.stub_responses(:describe_availability_zones, availability_zones: [
          {zone_name: "us-west-2a", zone_id: "usw2-az1"},
          {zone_name: "us-west-2b", zone_id: "usw2-az2"}
        ])

        expect { nx.backfill_old_subnet }.to hop("link_nics")
        expect(LocationAwsAz.where(location_id: location.id).count).to eq(2)
      end

      it "fails if AZ not found even after fetching from AWS" do
        LocationAwsAz.where(id: az_a.id).destroy

        client.stub_responses(:describe_subnets, subnets: [{
          subnet_id: "subnet-old",
          cidr_block: "10.0.0.0/26",
          availability_zone: "us-west-2x",
          ipv_6_cidr_block_association_set: []
        }])
        client.stub_responses(:describe_availability_zones, availability_zones: [
          {zone_name: "us-west-2b", zone_id: "usw2-az2"}
        ])

        expect { nx.backfill_old_subnet }.to raise_error("Could not find LocationAwsAz for AZ x")
      end
    end

    describe "#link_nics" do
      before do
        st.update(label: "link_nics")
        # Create the AwsSubnet record that would exist after backfill_old_subnet
        AwsSubnet.create(
          private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id,
          location_aws_az_id: az_a.id,
          ipv4_cidr: "10.0.0.0/26",
          subnet_id: "subnet-old"
        )
        nic  # ensure NIC is created
      end

      it "links NIC to AwsSubnet and hops to finish for old subnet" do
        expect { nx.link_nics }.to hop("finish")
        expect(nic.reload.nic_aws_resource.aws_subnet_id).not_to be_nil
      end

      it "skips NICs without nic_aws_resource" do
        nic.nic_aws_resource.destroy
        expect { nx.link_nics }.to hop("finish")
      end

      it "skips NICs already linked" do
        aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id).first
        nic.nic_aws_resource.update(aws_subnet_id: aws_subnet.id)
        expect { nx.link_nics }.to hop("finish")
      end
    end
  end

  describe "new /16 VPCs" do
    let(:ps) {
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-new-ps", location_id: location.id).subject
      ps.private_subnet_aws_resource.update(
        vpc_id: "vpc-new",
        route_table_id: "rtb-new",
        security_group_id: "sg-new",
        internet_gateway_id: "igw-new"
      )
      # Remove AwsSubnet records to simulate pre-migration state
      ps.private_subnet_aws_resource.aws_subnets.each(&:destroy)
      ps
    }

    let(:st) {
      Strand.create(prog: "Vnet::Aws::BackfillAwsSubnets", label: "start", stack: [{"subject_id" => ps.id}])
    }

    let(:nic_a) {
      nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic-a").subject
      NicAwsResource.create_with_id(nic.id, subnet_id: "subnet-a", subnet_az: "a")
      nic
    }

    let(:nic_b) {
      nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic-b").subject
      NicAwsResource.create_with_id(nic.id, subnet_id: "subnet-b", subnet_az: "us-west-2b")
      nic
    }

    describe "#start" do
      it "hops to fetch_existing_subnets for /16 VPCs" do
        expect { nx.start }.to hop("fetch_existing_subnets")
      end
    end

    describe "#fetch_existing_subnets" do
      before do
        st.update(label: "fetch_existing_subnets")
        az_b
        nic_a
        nic_b
      end

      it "groups subnets by AZ and stores in frame" do
        client.stub_responses(:describe_subnets, subnets: [
          {subnet_id: "subnet-a", cidr_block: "#{ps.net4.network}/24", availability_zone: "us-west-2a",
           ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14:1000::/64"}]},
          {subnet_id: "subnet-a2", cidr_block: "#{ps.net4.network}/24", availability_zone: "us-west-2a",
           ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14:1000:100::/64"}]},
          {subnet_id: "subnet-b", cidr_block: "#{ps.net4.nth_subnet(24, 1).network}/24", availability_zone: "us-west-2b",
           ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14:1000:200::/64"}]}
        ])

        expect { nx.fetch_existing_subnets }.to hop("create_records")
        frame = nx.strand.reload.stack.first
        expect(frame["az_subnet_map"].keys).to contain_exactly("a", "b")
        expect(frame["az_subnet_map"]["a"]["subnet_id"]).to eq("subnet-a")
        expect(frame["az_subnet_map"]["b"]["subnet_id"]).to eq("subnet-b")
      end

      it "handles VPC with no existing subnets" do
        client.stub_responses(:describe_subnets, subnets: [])
        expect { nx.fetch_existing_subnets }.to hop("create_records")
        frame = nx.strand.reload.stack.first
        expect(frame["az_subnet_map"]).to eq({})
      end
    end

    describe "#create_records" do
      before do
        az_b
        az_c
        st.update(label: "create_records")
      end

      it "creates AwsSubnet records for each AZ with existing and calculated CIDRs" do
        st.stack.first["az_subnet_map"] = {
          "a" => {"subnet_id" => "subnet-a", "cidr_block" => "#{ps.net4.network}/24", "ipv6_cidr" => "2600:1f14:1000::/64"}
        }
        st.modified!(:stack)
        st.save_changes

        expect { nx.create_records }.to hop("link_nics")
        aws_subnets = AwsSubnet.where(private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id).all
        expect(aws_subnets.count).to eq(3)

        az_a_subnet = aws_subnets.find { it.location_aws_az_id == az_a.id }
        expect(az_a_subnet.subnet_id).to eq("subnet-a")
        expect(az_a_subnet.ipv6_cidr.to_s).to eq("2600:1f14:1000::/64")

        az_b_subnet = aws_subnets.find { it.location_aws_az_id == az_b.id }
        expect(az_b_subnet.subnet_id).to be_nil
        expect(az_b_subnet.ipv6_cidr).to be_nil

        az_c_subnet = aws_subnets.find { it.location_aws_az_id == az_c.id }
        expect(az_c_subnet.subnet_id).to be_nil
      end
    end

    describe "#link_nics" do
      before do
        az_b
        st.update(label: "link_nics")
        # Create AwsSubnet records
        AwsSubnet.create(
          private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id,
          location_aws_az_id: az_a.id,
          ipv4_cidr: "#{ps.net4.network}/24",
          subnet_id: "subnet-a"
        )
        AwsSubnet.create(
          private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id,
          location_aws_az_id: az_b.id,
          ipv4_cidr: ps.net4.nth_subnet(24, 1).to_s
        )
        nic_a
        nic_b
      end

      it "links NICs by AZ suffix and hops to create_missing_az_subnets" do
        expect { nx.link_nics }.to hop("create_missing_az_subnets")
        aws_subnet_a = AwsSubnet.where(location_aws_az_id: az_a.id).first
        aws_subnet_b = AwsSubnet.where(location_aws_az_id: az_b.id).first
        expect(nic_a.reload.nic_aws_resource.aws_subnet_id).to eq(aws_subnet_a.id)
        expect(nic_b.reload.nic_aws_resource.aws_subnet_id).to eq(aws_subnet_b.id)
      end

      it "skips NICs without subnet_az" do
        nic_a.nic_aws_resource.update(subnet_az: nil)
        expect { nx.link_nics }.to hop("create_missing_az_subnets")
        expect(nic_a.reload.nic_aws_resource.aws_subnet_id).to be_nil
      end

      it "skips NICs with unmatched AZ" do
        nic_a.nic_aws_resource.update(subnet_az: "us-west-2z")
        expect { nx.link_nics }.to hop("create_missing_az_subnets")
        expect(nic_a.reload.nic_aws_resource.aws_subnet_id).to be_nil
      end
    end

    describe "#create_missing_az_subnets" do
      before do
        az_b
        st.update(label: "create_missing_az_subnets")

        # AZ a has an existing subnet, AZ b does not
        AwsSubnet.create(
          private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id,
          location_aws_az_id: az_a.id,
          ipv4_cidr: "#{ps.net4.network}/24",
          subnet_id: "subnet-existing-a",
          ipv6_cidr: "2600:1f14:1000::/64"
        )
        AwsSubnet.create(
          private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id,
          location_aws_az_id: az_b.id,
          ipv4_cidr: ps.net4.nth_subnet(24, 1).to_s
        )

        client.stub_responses(:describe_vpcs, vpcs: [{
          vpc_id: "vpc-new",
          ipv_6_cidr_block_association_set: [{ipv_6_cidr_block: "2600:1f14:1000::/56"}]
        }])
        client.stub_responses(:create_subnet, ->(context) {
          az = context.params[:availability_zone]
          {subnet: {subnet_id: "subnet-#{az}"}}
        })
        client.stub_responses(:modify_subnet_attribute)
      end

      it "creates AWS subnets for AZs without subnet_id and skips existing" do
        expect(client).to receive(:create_subnet).once.and_call_original
        expect(client).to receive(:modify_subnet_attribute).once.and_call_original
        expect { nx.create_missing_az_subnets }.to hop("associate_route_tables")

        az_a_subnet = AwsSubnet.where(location_aws_az_id: az_a.id, private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id).first
        expect(az_a_subnet.subnet_id).to eq("subnet-existing-a")

        az_b_subnet = AwsSubnet.where(location_aws_az_id: az_b.id, private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id).first
        expect(az_b_subnet.subnet_id).to eq("subnet-us-west-2b")
        expect(az_b_subnet.ipv6_cidr).not_to be_nil
      end

      it "hops to associate_route_tables when all subnets already exist" do
        AwsSubnet.where(location_aws_az_id: az_b.id, private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id)
          .update(subnet_id: "subnet-existing-b", ipv6_cidr: "2600:1f14:1000:100::/64")
        expect(client).not_to receive(:create_subnet)
        expect { nx.create_missing_az_subnets }.to hop("associate_route_tables")
      end
    end

    describe "#associate_route_tables" do
      before do
        az_b
        st.update(label: "associate_route_tables")

        AwsSubnet.create(
          private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id,
          location_aws_az_id: az_a.id,
          ipv4_cidr: "#{ps.net4.network}/24",
          subnet_id: "subnet-a"
        )
        AwsSubnet.create(
          private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id,
          location_aws_az_id: az_b.id,
          ipv4_cidr: ps.net4.nth_subnet(24, 1).to_s,
          subnet_id: "subnet-b"
        )
      end

      it "associates route tables for all subnets and hops to finish" do
        client.stub_responses(:associate_route_table)
        expect(client).to receive(:associate_route_table).with({
          route_table_id: "rtb-new",
          subnet_id: "subnet-a"
        }).and_call_original
        expect(client).to receive(:associate_route_table).with({
          route_table_id: "rtb-new",
          subnet_id: "subnet-b"
        }).and_call_original
        expect { nx.associate_route_tables }.to hop("finish")
      end

      it "ignores ResourceAlreadyAssociated errors" do
        client.stub_responses(:associate_route_table, Aws::EC2::Errors::ResourceAlreadyAssociated.new(nil, nil))
        expect { nx.associate_route_tables }.to hop("finish")
      end
    end
  end

  describe "#finish" do
    let(:ps) {
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-fin-ps", location_id: location.id).subject
      ps.private_subnet_aws_resource.update(vpc_id: "vpc-fin")
      ps.private_subnet_aws_resource.aws_subnets.each(&:destroy)
      ps
    }

    let(:st) {
      Strand.create(prog: "Vnet::Aws::BackfillAwsSubnets", label: "finish", stack: [{"subject_id" => ps.id}])
    }

    it "pops with success message" do
      expect { nx.finish }.to exit({"msg" => "AwsSubnet records backfilled successfully"})
    end
  end
end
