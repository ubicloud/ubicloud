# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PrivateLinkService do
  let(:project) { Project.create(name: "test-prj") }
  let(:aws_location) { create_location("aws") }
  let(:pls) { create_pls(aws_location) }
  let(:aws) { pls.private_link_service_aws_resource }

  # AWS uses the real region name: VM and PostgreSQL assembly look up
  # billing rates and AMIs by location name and the fixtures cover us-west-2.
  def create_location(provider)
    name = (provider == "aws") ? "us-west-2" : "#{provider}-loc"
    loc = Location.create(
      name:, provider:, project_id: project.id,
      display_name: "#{name}-cell-0", ui_name: "#{provider} loc", visible: true,
    )
    LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1") if provider == "aws"
    loc
  end

  def create_pls(location, name: "test-es")
    ps = PrivateSubnet.create(name: "#{name}-ps", project_id: project.id, location_id: location.id, net4: "10.0.0.0/26", net6: "fdfa::/64")
    pls = described_class.create(name:, project_id: project.id, location_id: ps.location_id, private_subnet_id: ps.id)
    PrivateLinkServiceAwsResource.create_with_id(pls) if location.aws?
    pls
  end

  it "derives location, path and defaults from its private subnet" do
    expect(pls.location).to eq aws_location
    expect(pls.location_id).to eq pls.private_subnet.location_id
    expect(pls.display_location).to eq "us-west-2-cell-0"
    expect(pls.path).to eq "/location/us-west-2-cell-0/private-link-service/test-es"
    expect(pls.allowed_principals).to eq []
    expect(pls.ip_address_type).to eq "ipv4"
  end

  describe "as a child of its private subnet" do
    it "cannot change its location or project either, since the composite key pins them to the subnet" do
      expect { pls.update(location_id: Location::HETZNER_FSN1_ID) }.to raise_error(RuntimeError, /cannot move to another private subnet/)
      expect { pls.update(project_id: Project.create(name: "other").id) }.to raise_error(RuntimeError, /cannot move to another private subnet/)
    end

    it "cannot move to another private subnet" do
      other_ps = PrivateSubnet.create(name: "other-ps", project_id: project.id, location_id: aws_location.id, net4: "10.1.0.0/26", net6: "fdfb::/64")
      expect { pls.update(private_subnet_id: other_ps.id) }.to raise_error(RuntimeError, /cannot move to another private subnet/)
      expect(pls.reload.private_subnet_id).not_to eq other_ps.id
    end

    it "must carry the subnet's project and location" do
      other_project = Project.create(name: "other-prj")
      expect {
        described_class.create(name: "cross-project", project_id: other_project.id, location_id: pls.location_id, private_subnet_id: pls.private_subnet_id)
      }.to raise_error(Sequel::ValidationFailed, /private_subnet_id and project_id and location_id is invalid/)
      expect {
        described_class.create(name: "cross-location", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, private_subnet_id: pls.private_subnet_id)
      }.to raise_error(Sequel::ValidationFailed, /private_subnet_id and project_id and location_id is invalid/)
    end

    it "has a name unique within its project and location, even across subnets" do
      other_ps = PrivateSubnet.create(name: "other-ps", project_id: project.id, location_id: aws_location.id, net4: "10.1.0.0/26", net6: "fdfb::/64")
      expect {
        described_class.create(name: pls.name, project_id: project.id, location_id: other_ps.location_id, private_subnet_id: other_ps.id)
      }.to raise_error(Sequel::ValidationFailed, /project_id and location_id and name is already taken/)

      other_location = Location.create(name: "us-east-1", display_name: "us-east-1-cell-0", ui_name: "us-east-1", visible: true, provider: "aws", project_id: project.id)
      LocationAz.create(location_id: other_location.id, az: "a", zone_id: "use1-az1")
      far_ps = PrivateSubnet.create(name: "far-ps", project_id: project.id, location_id: other_location.id, net4: "10.2.0.0/26", net6: "fdfc::/64")
      twin = described_class.create(name: pls.name, project_id: project.id, location_id: far_ps.location_id, private_subnet_id: far_ps.id)
      expect(twin.location).to eq other_location
    end
  end

  describe "#display_state" do
    it "is deleting without a strand" do
      expect(pls.display_state).to eq "deleting"
    end

    it "follows the strand label" do
      st = Strand.create_with_id(pls, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "start")
      expect(pls.reload.display_state).to eq "creating"

      st.update(label: "wait")
      expect(pls.reload.display_state).to eq "available"

      # Background modes run from wait do not make the service unavailable.
      %w[verify_private_dns reconcile_connections update_permissions].each do |label|
        st.update(label:)
        expect(pls.reload.display_state).to eq "available"
      end

      st.update(label: "destroy")
      expect(pls.reload.display_state).to eq "deleting"

      # The teardown chain has cleared the destroy semaphore by then.
      %w[recover_unrecorded_ids delete_nlb].each do |label|
        st.update(label:)
        expect(pls.reload.display_state).to eq "deleting"
      end
    end

    it "is deleting once destroy is requested" do
      Strand.create_with_id(pls, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "wait")
      pls.incr_destroy
      expect(pls.reload.display_state).to eq "deleting"
    end
  end

  def create_vm(ps, name)
    Prog::Vm::Nexus.assemble("k y", project.id, name:, private_subnet_id: ps.id, location_id: ps.location_id).subject
  end

  # The resource is moved into the service's subnet, as the foreign key requires.
  def create_pg(name = "pg-aws")
    allow(Config).to receive(:postgres_service_project_id).and_return(Project.create(name: "postgres-service").id)
    pg = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id, location_id: aws_location.id, name:,
      target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16",
    ).subject
    pg.update(private_subnet_id: pls.private_subnet_id)
    pg
  end

  def serve_pg_zone(pg)
    zone = DnsZone.create(project_id: Config.postgres_service_project_id, name: pg.hostname_suffix)
    server = DnsServer.create(name: "ns.#{pg.hostname_suffix}")
    zone.add_dns_server(server)
    server.add_vm(create_vm(pls.private_subnet, "dns-#{pg.name}"))
    zone
  end

  describe "#target_vms" do
    it "is empty without an attached resource" do
      expect(pls.target_vms).to eq []
    end

    it "is empty while the attached resource has no representative server" do
      pg = create_pg
      pg.servers_dataset.update(is_representative: false)
      pls.update(postgres_resource_id: pg.id)
      expect(pls.target_vms).to eq []
    end

    it "is the attached resource's representative server VM" do
      pg = create_pg
      pls.update(postgres_resource_id: pg.id)
      expect(pls.target_vms.map(&:id)).to eq [pg.representative_server.vm_id]
    end
  end

  it "stores cleaned principals and asks for them to be applied without a full reconcile" do
    Strand.create_with_id(pls, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "wait")
    pls.update_allowed_principals([" arn:aws:iam::1:root ", "arn:aws:iam::1:root", "arn:aws:iam::2:root"])
    expect(pls.reload.allowed_principals).to eq ["arn:aws:iam::1:root", "arn:aws:iam::2:root"]
    expect(pls.update_permissions_set?).to be true
    expect(pls.reconcile_set?).to be false
  end

  it "derives the private DNS name only from a resource whose DNS zone Ubicloud serves" do
    pg = create_pg
    expect(described_class.default_private_dns_name(nil)).to be_nil
    expect(described_class.default_private_dns_name(pg)).to be_nil

    zone = DnsZone.create(project_id: Config.postgres_service_project_id, name: pg.hostname_suffix)
    expect(described_class.default_private_dns_name(pg)).to be_nil

    server = DnsServer.create(name: "ns.#{pg.hostname_suffix}")
    zone.add_dns_server(server)
    expect(described_class.default_private_dns_name(pg)).to be_nil

    server.add_vm(create_vm(pls.private_subnet, "dns-vm"))
    expect(described_class.default_private_dns_name(pg)).to eq "*.#{pg.ubid}.private.#{pg.hostname_suffix}"
    expect(described_class.default_private_dns_name(pg)).to eq pg.cert_private_hostname

    pg.update(hostname_version: "v1")
    expect(described_class.default_private_dns_name(pg)).to be_nil
  end

  describe "managed private DNS zone" do
    def zone_with_server(name, with_vm: true)
      zone = DnsZone.create(project_id: project.id, name:)
      server = DnsServer.create(name: "ns.#{name}")
      zone.add_dns_server(server)
      server.add_vm(create_vm(pls.private_subnet, "dns-#{name.tr(".", "-")}")) if with_vm
      zone
    end

    it "has no domain or zone without a private DNS name" do
      expect(pls.private_dns_domain).to be_nil
      expect(pls.managed_private_dns_zone).to be_nil
    end

    it "verifies a wildcard name at its domain" do
      pls.update(private_dns_name: "*.c0.example.com")
      expect(pls.private_dns_domain).to eq "c0.example.com"
    end

    it "is nil for a customer domain and for a zone without DNS server VMs" do
      pls.update(private_dns_name: "db.c0.example.com")
      expect(pls.managed_private_dns_zone).to be_nil

      zone_with_server("c0.example.com", with_vm: false)
      expect(pls.managed_private_dns_zone).to be_nil
    end

    it "is the longest served zone containing the name" do
      pls.update(private_dns_name: "db.c0.example.com")
      parent = zone_with_server("example.com")
      expect(pls.managed_private_dns_zone).to eq parent

      child = zone_with_server("c0.example.com")
      expect(pls.managed_private_dns_zone).to eq child
    end
  end

  it "destroys its provider row and its ports, with their provider rows, with it" do
    port = PrivateLinkServicePort.create(private_link_service_id: pls.id, port: 5432, target_port: 5432)
    PrivateLinkServicePortAwsResource.create(target_group_arn: "arn:tg") { it.id = port.id }
    expect(pls.ports.count).to eq 1
    expect(aws).not_to be_nil

    pls.destroy
    expect(PrivateLinkServicePort.where(private_link_service_id: pls.id).count).to eq 0
    expect(PrivateLinkServicePortAwsResource[port.id]).to be_nil
    expect(PrivateLinkServiceAwsResource[pls.id]).to be_nil
  end

  it "refuses a second PostgreSQL resource while one is attached, keeping the first and its name" do
    Strand.create_with_id(pls, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "wait")
    pg_a, pg_b = %w[pg-a pg-b].map { create_pg(it) }
    serve_pg_zone(pg_a)

    pls.attach_postgres_resource(pg_a)
    pls.decr_reconcile
    expect { pls.attach_postgres_resource(pg_b) }.to raise_error(Validation::ValidationFailed) { expect(it.details).to eq("postgres_resource_id" => "A PostgreSQL resource is already attached") }
    expect(pls.reload.postgres_resource_id).to eq pg_a.id
    expect(pls.private_dns_name).to eq pg_a.cert_private_hostname
    expect(pls.private_hostname).to eq pg_a.private_hostname
    expect(pls.reconcile_set?).to be false

    pls.update(postgres_resource_id: nil)
    expect(pls.private_hostname).to be_nil
  end

  it "refuses a PostgreSQL resource that already has a private link service" do
    Strand.create_with_id(pls, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "wait")
    pg = create_pg
    pls.attach_postgres_resource(pg)

    pls2 = described_class.create(name: "test-es-2", project_id: project.id, location_id: pls.location_id, private_subnet_id: pls.private_subnet_id)
    expect { pls2.attach_postgres_resource(pg) }.to raise_error(Validation::ValidationFailed) { expect(it.details).to eq("postgres_resource_id" => "PostgreSQL resource already has a private link service") }
    expect(pls2.reload.postgres_resource_id).to be_nil
    expect(pg.reload.private_link_service.id).to eq pls.id
  end

  it "attaches a PostgreSQL resource and requests a reconcile" do
    Strand.create_with_id(pls, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "wait")
    pg = create_pg

    aws.update(private_dns_verification_attempted_at: Time.now)
    pls.attach_postgres_resource(pg)
    expect(pls.reload.postgres_resource_id).to eq pg.id
    expect(pls.private_dns_name).to be_nil
    expect(pls.private_hostname).to eq pg.private_hostname
    expect(aws.reload.private_dns_verification_attempted_at).to be_nil
    expect(pls.reconcile_set?).to be true

    serve_pg_zone(pg)
    pls.update(postgres_resource_id: nil)
    pls2 = described_class.create(name: "test-es-2", project_id: project.id, location_id: pls.location_id, private_subnet_id: pls.private_subnet_id)
    aws2 = PrivateLinkServiceAwsResource.create_with_id(pls2, private_dns_verification_attempted_at: Time.now)
    Strand.create_with_id(pls2, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "wait")
    pls2.attach_postgres_resource(pg)
    expect(pls2.reload.postgres_resource_id).to eq pg.id
    expect(pls2.private_dns_name).to eq "*.#{pg.ubid}.private.#{pg.hostname_suffix}"
    expect(pls2.private_dns_name).to eq pg.cert_private_hostname
    expect(aws2.reload.private_dns_verification_attempted_at).to be_nil
    expect(pg.reload.private_link_service.id).to eq pls2.id
  end

  describe "provider dispatch" do
    let(:gcp_pls) { create_pls(create_location("gcp")) }
    let(:metal_pls) { create_pls(Location[Location::HETZNER_FSN1_ID]) }

    it "forgets the AWS private DNS verification attempt on the companion row" do
      aws.update(private_dns_verification_attempted_at: Time.now)
      pls.forget_private_dns_verification
      expect(aws.reload.private_dns_verification_attempted_at).to be_nil
    end

    it "has nothing to forget on GCP" do
      expect(gcp_pls.forget_private_dns_verification).to be_nil
    end

    it "is not supported on metal" do
      expect { metal_pls.forget_private_dns_verification }.to raise_error(RuntimeError, /not supported on metal/)
    end
  end
end
