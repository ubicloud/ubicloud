# frozen_string_literal: true

require "aws-sdk-ec2"

RSpec.describe LocationAz do
  let(:project) { Project.create(name: "test-az-prj") }
  let(:location) {
    loc = Location.create(name: "us-west-2", provider: "aws", project_id: project.id, display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
    LocationCredential.create_with_id(loc.id, access_key: "stubbed-akid", secret_key: "stubbed-secret")
    loc
  }

  before do
    aws_credentials = Aws::Credentials.new("stubbed-akid", "stubbed-secret")
    allow(Aws::Credentials).to receive(:new).with("stubbed-akid", "stubbed-secret").and_return(aws_credentials)
    allow(Aws::EC2::Client).to receive(:new).and_return(Aws::EC2::Client.new(stub_responses: true))
  end

  it "supports CRUD and lookups" do
    az = described_class.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
    expect(described_class[az.id]).to eq(az)
    expect(described_class[location_id: location.id, az: "a"]).to eq(az)
    expect(az.location).to eq(location)

    az.destroy
    expect(described_class[az.id]).to be_nil
  end

  describe "end-to-end with AwsSubnet and NIC" do
    it "full lifecycle: described_class -> AwsSubnet -> NIC creation and lookups" do
      az_a = described_class.create(location_id: location.id, az: "a", zone_id: "usw2-az1")
      az_b = described_class.create(location_id: location.id, az: "b", zone_id: "usw2-az2")

      # Location.azs returns described_class records
      expect(location.azs).to contain_exactly(az_a, az_b)
      expect(location.location_azs_dataset.where(az: "a").first).to eq(az_a)

      # SubnetNexus.assemble creates PrivateSubnetAwsResource + AwsSubnet records
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "e2e-ps", location_id: location.id).subject

      # AwsSubnet records exist and point back to described_class
      aws_subnets = ps.private_subnet_aws_resource.aws_subnets
      expect(aws_subnets.size).to eq(2)
      aws_subnets.each do |s|
        expect(s.location_az).to be_a(described_class)
        expect(s.az_suffix).to eq(s.location_az.az)
        # FK column is still named location_aws_az_id
        expect(s.location_aws_az_id).not_to be_nil
      end

      # select_aws_subnet: preferred AZ
      subnet_b = Prog::Vnet::NicNexus.select_aws_subnet(ps, "b", [])
      expect(subnet_b.location_az).to eq(az_b)

      # select_aws_subnet: exclude AZ
      subnet_excl = Prog::Vnet::NicNexus.select_aws_subnet(ps, nil, ["a"])
      expect(subnet_excl.location_az).to eq(az_b)

      # select_aws_subnet: fallback when all excluded
      subnet_any = Prog::Vnet::NicNexus.select_aws_subnet(ps, nil, ["a", "b"])
      expect(subnet_any).to be_an(AwsSubnet)

      # allocate_ipv4_from_aws_subnet
      ip = Prog::Vnet::NicNexus.allocate_ipv4_from_aws_subnet(ps, subnet_b)
      expect(ip).to match(%r{\A\d+\.\d+\.\d+\.\d+/32\z})

      # NIC assembly end-to-end
      nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "e2e-nic").subject
      expect(nic.private_ipv4).not_to be_nil
      expect(nic.private_ipv6).not_to be_nil
      expect(nic.state).to eq("active")
      expect(nic.strand.prog).to eq("Vnet::Aws::NicNexus")
    end
  end
end
