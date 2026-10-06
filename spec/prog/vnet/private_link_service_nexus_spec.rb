# frozen_string_literal: true

RSpec.describe Prog::Vnet::PrivateLinkServiceNexus do
  let(:project) { Project.create(name: "test-prj") }

  let(:aws_location) do
    loc = Location.create(
      name: "us-west-2", provider: "aws", project_id: project.id,
      display_name: "aws-us-west-2", ui_name: "AWS US West 2", visible: true,
    )
    LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
    loc
  end

  let(:ps) { Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: aws_location.id).subject }
  let(:st) { assemble(name: "test-es", allowed_principals: ["arn:aws:iam::123456789012:root"]) }
  let(:pls) { st.subject }

  # Every keyword is required; these are the values the web form posts when
  # the user changes nothing.
  def assemble(**)
    described_class.assemble(
      project_id: project.id, private_subnet_id: ps.id, allowed_principals: [], postgres_resource_id: nil,
      ports: [[5432, 5432], [6432, 6432]], ip_address_type: "ipv4", aws_supported_regions: [], aws_allowed_vpc_endpoints: [], **,
    )
  end

  describe ".assemble" do
    it "fails without a private subnet" do
      expect { assemble(private_subnet_id: "00000000-0000-0000-0000-000000000000", name: "x") }.to raise_error("No existing private subnet")
    end

    it "fails outside AWS" do
      hetzner_ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "hetzner-ps", location_id: Location::HETZNER_FSN1_ID).subject
      expect { assemble(private_subnet_id: hetzner_ps.id, name: "x") }.to raise_error("Private link services are only supported on AWS")
    end

    it "fails without ports" do
      expect { assemble(name: "x", ports: []) }.to raise_error("Private link service must have at least one port")
    end

    it "stores the IP address type" do
      expect(assemble(name: "dual", ip_address_type: "dual").subject.ip_address_type).to eq "dual"
    end

    it "fails with an invalid name" do
      expect { assemble(name: "Bad Name") }.to raise_error(Validation::ValidationFailed)
    end

    it "stores extra supported regions sorted and unique, without the home region, rejecting unknown ones" do
      pls = assemble(name: "regions", aws_supported_regions: ["us-east-1", "eu-west-1", "us-east-1", "us-west-2"]).subject
      expect(pls.private_link_service_aws_resource.supported_regions).to eq ["eu-west-1", "us-east-1"]
      expect { assemble(name: "bad", aws_supported_regions: ["mars-1"]) }.to raise_error("Unsupported AWS region for cross-region access")
    end

    it "creates the service, the given ports, the AWS companion rows and the AWS nexus strand in start" do
      expect(st.label).to eq "start"
      expect(st.prog).to eq "Vnet::Aws::PrivateLinkServiceNexus"
      expect(pls).to be_a(PrivateLinkService)
      expect(pls.private_subnet_id).to eq ps.id
      expect(pls.location).to eq aws_location
      expect(pls.allowed_principals).to eq ["arn:aws:iam::123456789012:root"]
      expect(pls.ports.map { [it.port, it.target_port] }.sort).to eq [[5432, 5432], [6432, 6432]]
      expect(pls.private_dns_name).to be_nil
      expect(pls.ip_address_type).to eq "ipv4"

      aws = pls.private_link_service_aws_resource
      expect(aws).to be_a(PrivateLinkServiceAwsResource)
      expect(aws.supported_regions).to eq []
      expect(aws.allowed_endpoints).to eq []
      expect(aws.nlb_arn).to be_nil
      expect(pls.ports.map { it.private_link_service_port_aws_resource }).to all(be_a(PrivateLinkServicePortAwsResource))
      expect(pls.ports.map { it.private_link_service_port_aws_resource.target_group_arn }).to eq [nil, nil]
    end

    it "stores custom ports and approved consumer endpoints" do
      pls = assemble(name: "custom", ports: [[15432, 5432]], aws_allowed_vpc_endpoints: [["vpce-b", "team b"], ["vpce-a", ""]]).subject
      expect(pls.ports.map { [it.port, it.target_port] }).to eq [[15432, 5432]]
      expect(pls.private_dns_name).to be_nil
      expect(pls.private_link_service_aws_resource.allowed_endpoints.map { [it.vpc_endpoint_id, it.description] }).to eq [["vpce-a", ""], ["vpce-b", "team b"]]
    end

    it "derives the private DNS name of a PostgreSQL-backed service from the resource once its zone is served" do
      allow(Config).to receive(:postgres_service_project_id).and_return(Project.create(name: "postgres-service").id)
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: project.id, location_id: aws_location.id, name: "pg-aws",
        target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16",
      ).subject
      pg.update(private_subnet_id: ps.id)

      zone = DnsZone.create(project_id: Config.postgres_service_project_id, name: pg.hostname_suffix)
      bare = assemble(name: "pg-es-bare", postgres_resource_id: pg.id).subject
      expect(bare.private_dns_name).to be_nil
      bare.update(postgres_resource_id: nil)

      server = DnsServer.create(name: "ns.#{pg.hostname_suffix}")
      zone.add_dns_server(server)
      server.add_vm(Prog::Vm::Nexus.assemble("k y", project.id, name: "dns-vm", private_subnet_id: ps.id, location_id: aws_location.id).subject)
      pls = assemble(name: "pg-es", postgres_resource_id: pg.id).subject
      expect(pls.private_dns_name).to eq "*.#{pg.ubid}.private.#{pg.hostname_suffix}"
    end
  end
end
