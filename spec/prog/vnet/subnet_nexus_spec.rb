# frozen_string_literal: true

RSpec.describe Prog::Vnet::SubnetNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:prj) { Project.create(name: "default") }
  let(:ps) {
    PrivateSubnet.create(name: "ps", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "1.1.1.0/26", state: "waiting", project_id: prj.id)
  }

  let(:ps2) {
    PrivateSubnet.create(name: "ps2", location_id: Location::HETZNER_FSN1_ID, net6: "fd10:9b0b:6b4b:8fcc::/64",
      net4: "1.1.1.128/26", state: "waiting", project_id: prj.id)
  }

  before do
    nx.instance_variable_set(:@private_subnet, ps)
  end

  describe ".until_random_ip" do
    it "raises if no ip is found by the block after 1000 iterations" do
      i = 0
      expect {
        described_class.until_random_ip("bad") do
          i += 1
          nil
        end
      }.to raise_error RuntimeError, "bad"
      expect(i).to eq 1000
    end

    it "returns first ip found by block" do
      ips = [nil, nil, "1.2.3.4", "1.2.3.5"]
      ip = described_class.until_random_ip("bad") { ips.shift }
      expect(ip).to eq "1.2.3.4"
      expect(ips).to eq ["1.2.3.5"]
    end
  end

  describe ".assemble" do
    it "fails if project doesn't exist" do
      expect {
        described_class.assemble(nil)
      }.to raise_error RuntimeError, "No existing project"
    end

    it "fails if location doesn't exist" do
      expect {
        described_class.assemble(prj.id, location_id: nil)
      }.to raise_error RuntimeError, "No existing location"
    end

    it "uses ipv6_addr if passed and creates entities" do
      expect(described_class).to receive(:random_private_ipv4).and_return("10.0.0.0/26")
      ps = described_class.assemble(
        prj.id,
        name: "default-ps",
        location_id: Location::HETZNER_FSN1_ID,
        ipv6_range: "fd10:9b0b:6b4b:8fbb::/64"
      )

      expect(ps.subject.net6.to_s).to eq("fd10:9b0b:6b4b:8fbb::/64")
    end

    it "uses ipv4_addr if passed and creates entities" do
      expect(described_class).to receive(:random_private_ipv6).and_return("fd10:9b0b:6b4b:8fbb::/64")
      ps = described_class.assemble(
        prj.id,
        name: "default-ps",
        location_id: Location::HETZNER_FSN1_ID,
        ipv4_range: "10.0.0.0/26"
      )

      expect(ps.subject.net4.to_s).to eq("10.0.0.0/26")
    end

    it "uses firewall if provided" do
      fw = Firewall.create(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: prj.id)
      ps = described_class.assemble(prj.id, firewall_id: fw.id)
      expect(ps.subject.firewalls.count).to eq(1)
      expect(ps.subject.firewalls.first).to eq(fw)
    end

    it "fails if provided firewall does not exist" do
      expect {
        described_class.assemble(prj.id, firewall_id: "550e8400-e29b-41d4-a716-446655440000")
      }.to raise_error RuntimeError, "Firewall with id 550e8400-e29b-41d4-a716-446655440000 and location hetzner-fsn1 does not exist"
    end

    it "fails if firewall is not in the project" do
      fw = Firewall.create(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Project.create(name: "t2").id)
      expect {
        described_class.assemble(prj.id, firewall_id: fw.id)
      }.to raise_error RuntimeError, "Firewall with id #{fw.id} and location hetzner-fsn1 does not exist"
    end

    it "fails if both allow_only_ssh and firewall_id are specified" do
      fw = Firewall.create(name: "default-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: prj.id)
      expect {
        described_class.assemble(prj.id, firewall_id: fw.id, allow_only_ssh: true)
      }.to raise_error RuntimeError, "Cannot specify both allow_only_ssh and firewall_id"
    end
  end

  describe ".random_private_ipv4" do
    it "returns a random private ipv4 range" do
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], prj)).to be_a NetAddr::IPv4Net
    end

    it "finds a new subnet if the one it found is taken" do
      expect(PrivateSubnet).to receive(:random_subnet).and_return("10.0.0.0/8").at_least(:once)
      project = Project.create(name: "test-project")
      described_class.assemble(project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-subnet", ipv4_range: "10.0.0.128/26")
      allow(SecureRandom).to receive(:random_number).with(2**(26 - 8) - 1).and_return(1, 2)
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project).to_s).to eq("10.0.0.192/26")
    end

    it "finds a new subnet if the one it found is banned" do
      expect(PrivateSubnet).to receive(:random_subnet).and_return("172.16.0.0/16", "10.0.0.0/8")
      project = Project.create(name: "test-project")
      allow(SecureRandom).to receive(:random_number).with(2**(26 - 16) - 1).and_return(1)
      allow(SecureRandom).to receive(:random_number).with(2**(26 - 8) - 1).and_return(1)
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project).to_s).to eq("10.0.0.128/26")
    end

    it "finds a new subnet if the initial range is smaller than the requested cidr range" do
      expect(PrivateSubnet).to receive(:random_subnet).and_return("172.16.0.0/16", "10.0.0.0/8")
      project = Project.create(name: "test-project")
      expect(SecureRandom).not_to receive(:random_number).with(2**(16 - 16) - 1)
      allow(SecureRandom).to receive(:random_number).with(2**(16 - 8) - 1).and_return(15)
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project, 16).to_s).to eq("10.16.0.0/16")
    end

    it "raises an error when invalid CIDR is given" do
      project = Project.create(name: "test-project")
      expect { described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project, 33) }.to raise_error(ArgumentError)
    end

    it "raises an error when no subnet is found" do
      project = Project.create(name: "test-project")
      expect { described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project, 8) }.to raise_error(RuntimeError, "No subnet found for cidr size 8")
    end

    it "filters out subnets that are smaller than the requested cidr size" do
      project = Project.create(name: "test-project")
      expect(SecureRandom).to receive(:random_number).with(2**(10 - 8) - 1).and_return(1)
      expect(described_class.random_private_ipv4(Location[name: "hetzner-fsn1"], project, 10).to_s).to eq("10.128.0.0/10")
    end
  end

  describe ".create_aws_subnet_records" do
    let(:aws_location) {
      loc = Location.create(name: "us-west-2", provider: "aws", project_id: prj.id, display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true)
      LocationCredential.create_with_id(loc.id, access_key: "test-key", secret_key: "test-secret")
      loc
    }

    it "raises error when VPC is too small for even a single subnet" do
      # /30 VPC with ipv4_range_size=30 -> ipv4_prefix=min(38,28)=28
      # Can't fit a /28 subnet in a /30 VPC
      LocationAwsAz.create(location_id: aws_location.id, az: "a", zone_id: "usw2-az1")
      small_ps = PrivateSubnet.create(name: "small-ps", location_id: aws_location.id, net6: "fd10::/64", net4: "10.0.0.0/30", state: "waiting", project_id: prj.id)
      ps_aws_resource = PrivateSubnetAwsResource.create_with_id(small_ps.id)

      expect {
        described_class.create_aws_subnet_records(small_ps, ps_aws_resource, aws_location, 30, false)
      }.to raise_error("Not enough subnet space for even a single AZ. Use a range size <= 28")
    end

    it "logs warning and skips AZs when VPC cannot fit all subnets" do
      # /26 VPC can fit 4 /28 subnets (indices 0-3)
      # Create 5 AZs - the 5th should be skipped with a log
      5.times do |i|
        LocationAwsAz.create(location_id: aws_location.id, az: ("a".ord + i).chr, zone_id: "usw2-az#{i + 1}")
      end
      limited_ps = PrivateSubnet.create(name: "limited-ps", location_id: aws_location.id, net6: "fd10::/64", net4: "10.0.0.0/26", state: "waiting", project_id: prj.id)
      ps_aws_resource = PrivateSubnetAwsResource.create_with_id(limited_ps.id)

      expect(Clog).to receive(:emit).with(/Not enough subnet space for AZ.*idx 4/)
      described_class.create_aws_subnet_records(limited_ps, ps_aws_resource, aws_location, 26, false)

      # Should have created 4 subnets, not 5
      expect(AwsSubnet.where(private_subnet_aws_resource_id: ps_aws_resource.id).count).to eq(4)
    end
  end

  describe ".random_private_ipv6" do
    it "returns a random private ipv6 range" do
      expect(described_class.random_private_ipv6(Location[name: "hetzner-fsn1"], prj)).to be_a NetAddr::IPv6Net
    end

    it "finds a new subnet if the one it found is taken" do
      project = Project.create(name: "test-project")
      described_class.assemble(project.id, location_id: Location::HETZNER_FSN1_ID, name: "test-subnet", ipv6_range: "fd61:6161:6161:6161::/64")
      expect(SecureRandom).to receive(:bytes).with(7).and_return("a" * 7, "b" * 7)
      expect(described_class.random_private_ipv6(Location[name: "hetzner-fsn1"], project).to_s).to eq("fd62:6262:6262:6262::/64")
    end
  end
end
