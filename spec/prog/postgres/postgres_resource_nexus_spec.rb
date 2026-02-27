# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresResourceNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource) }
  let(:st) { postgres_resource.strand }
  let(:postgres_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project:, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }

  def create_postgres_timeline(location_id: self.location_id)
    tl = PostgresTimeline.create(
      location_id:,
      access_key: "dummy-access-key",
      secret_key: "dummy-secret-key"
    )
    Strand.create_with_id(tl, prog: "Postgres::PostgresTimelineNexus", label: "wait")
    tl
  end

  def create_postgres_resource(location_id: self.location_id, project: self.project, with_strand: true, with_certs: true, private_subnet: self.private_subnet, name: "pg-test-resource")
    certs = if with_certs
      cert_pem, key_pem = Util.create_root_certificate(common_name: "Test Root CA", duration: 60 * 60 * 24 * 365 * 5)
      {root_cert_1: cert_pem, root_cert_key_1: key_pem, root_cert_2: cert_pem, root_cert_key_2: key_pem, server_cert: cert_pem, server_cert_key: key_pem}
    end

    pr = PostgresResource.create(
      name:,
      superuser_password: "dummy-password",
      target_version: "16",
      location_id:,
      project:,
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      private_subnet_id: private_subnet.id,
      **certs
    )
    Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "start") if with_strand
    pr
  end

  def create_postgres_server(resource:, location_id: self.location_id, timeline: create_postgres_timeline(location_id:), timeline_access: "push", is_representative: true, version: "16", private_subnet: self.private_subnet, vm_name: "pg-vm-#{resource.name}", server_index: 0)
    vm = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: vm_name, private_subnet_id: private_subnet.id,
      location_id:, unix_user: "ubi"
    ).subject
    VmStorageVolume.create(vm:, boot: false, size_gib: 64, disk_index: 1)
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.#{server_index + 1}/32")
    vm.update(ephemeral_net6: "fd10:9b0b:6b4b:#{server_index}::/79")
    server = PostgresServer.create(
      timeline:,
      resource:,
      vm_id: vm.id,
      is_representative:,
      timeline_access:,
      version:
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "start")
    server
  end

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  describe ".assemble" do
    let(:customer_project) { Project.create(name: "default") }
    let(:private_location) {
      loc = Location.create(
        name: "us-west-2",
        display_name: "aws-us-west-2",
        ui_name: "aws-us-west-2",
        visible: true,
        provider: "aws",
        project: postgres_project
      )
      LocationCredential.create(
        access_key: "access-key-id",
        secret_key: "secret-access-key"
      ) { it.id = loc.id }
      LocationAwsAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
      loc
    }

    it "validates input" do
      expect {
        described_class.assemble(project_id: "pjtyk9ryq65t1j01jpv00m03eb", location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: nil, name: "pg/server/name", target_vm_size: "standard-2", target_storage_size_gib: 128)
      }.to raise_error RuntimeError, "No existing location"

      expect {
        described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128)
      }.not_to raise_error

      expect {
        described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: "pgd2m9djgryj6nq73jrdddnkrt")
      }.to raise_error RuntimeError, "No existing parent"

      private_location.update(project: customer_project)
      described_class.assemble(project_id: customer_project.id, location_id: private_location.id, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 118)

      expect {
        parent = described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-parent-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject
        described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: parent.id, restore_target: Time.now)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: restore_target"
    end

    it "does not allow giving different version than parent for restore" do
      parent = described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-parent-name", target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16").subject
      expect {
        described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: parent.id, target_version: "17", restore_target: Time.now)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: version"
    end

    it "passes timeline of parent resource if parent is passed" do
      parent = described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject
      restore_target = Time.now
      parent.timeline.update(cached_earliest_backup_at: restore_target - 15 * 60)

      child_strand = described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name-2", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: parent.id, restore_target:)
      child = child_strand.subject
      expect(child.representative_server.timeline_id).to eq(parent.timeline.id)
      expect(child.representative_server.timeline_access).to eq("fetch")
    end

    it "creates internal firewall and customer private subnet and firewall" do
      pg = described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject

      private_subnet = pg.private_subnet
      expect(private_subnet.project_id).to eq customer_project.id

      customer_firewall = pg.customer_firewall
      expect(pg.private_subnet.firewalls).to eq [customer_firewall]
      expect(customer_firewall.project_id).to eq customer_project.id
      expect(customer_firewall.firewall_rules.map { "#{it.cidr}:#{it.port_range.to_range}" }.sort).to eq [
        "0.0.0.0/0:5432...5433",
        "0.0.0.0/0:6432...6433",
        "::/0:5432...5433",
        "::/0:6432...6433"
      ]

      internal_firewall = pg.internal_firewall
      expect(internal_firewall.project_id).to eq postgres_project.id
      expect(internal_firewall.firewall_rules.map { "#{it.cidr}:#{it.port_range.to_range}" }.sort).to eq [
        "0.0.0.0/0:22...23",
        "#{private_subnet.net4}:5432...5433",
        "#{private_subnet.net4}:6432...6433",
        "::/0:22...23",
        "#{private_subnet.net6}:5432...5433",
        "#{private_subnet.net6}:6432...6433"
      ]
    end

    it "uses Config.control_plane_outbound_cidrs to limit SSH access" do
      expect(Config).to receive(:control_plane_outbound_cidrs).and_return(["1.2.3.4/32"]).at_least(:once)
      pg = described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject

      internal_firewall = pg.internal_firewall
      expect(internal_firewall.firewall_rules.map { "#{it.cidr}:#{it.port_range.to_range}" }.sort).to eq [
        "1.2.3.4/32:22...23",
        "#{pg.private_subnet.net4}:5432...5433",
        "#{pg.private_subnet.net4}:6432...6433",
        "#{pg.private_subnet.net6}:5432...5433",
        "#{pg.private_subnet.net6}:6432...6433"
      ]
    end

    it "sets use_different_az semaphore for AWS locations when FF is set" do
      customer_project.set_ff_postgres_aws_use_different_azs_for_standbys(true)
      private_location.update(project: customer_project)

      pg = described_class.assemble(project_id: customer_project.id, location_id: private_location.id, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject

      expect(pg.use_different_az_set?).to be true
    end

    it "does not set use_different_az for non-AWS locations when FF is set" do
      customer_project.set_ff_postgres_aws_use_different_azs_for_standbys(true)

      pg = described_class.assemble(project_id: customer_project.id, location_id:, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject

      expect(pg.use_different_az_set?).to be false
    end

    it "does not set use_different_az when FF is not set" do
      private_location.update(project: customer_project)

      pg = described_class.assemble(project_id: customer_project.id, location_id: private_location.id, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject

      expect(pg.use_different_az_set?).to be false
    end
  end

  describe "#before_run" do
    it "hops to destroy and stops billing records when needed" do
      postgres_server
      # Use a past start time so that finalize results in a non-empty span
      # (within a transaction, now() returns the same time, so span would be empty otherwise)
      past_span = Sequel.pg_range((Time.now - 3600)..)
      br1 = BillingRecord.create(
        project_id: project.id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresVCpu", "standard-standard", "hetzner-fsn1", false)["id"],
        amount: 2,
        span: past_span
      )
      br2 = BillingRecord.create(
        project_id: project.id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresStorage", "standard", "hetzner-fsn1", false)["id"],
        amount: 64,
        span: past_span
      )
      fresh_nx = described_class.new(st)
      fresh_nx.incr_destroy
      expect { fresh_nx.before_run }.to hop("destroy")
      expect(br1.reload.span.end).not_to be_nil
      expect(br2.reload.span.end).not_to be_nil
    end

    it "does not hop to destroy if already in the destroy state" do
      postgres_server
      nx.incr_destroy
      st.update(label: "destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the wait_children_destroyed state" do
      postgres_server
      nx.incr_destroy
      st.update(label: "wait_children_destroyed")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "pops if in trigger_pg_current_xact_id_on_parent state and has a parent" do
      postgres_server
      nx.incr_destroy
      st.update(label: "trigger_pg_current_xact_id_on_parent")
      expect { nx.before_run }.to exit({"msg" => "exiting early due to destroy semaphore"})
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      postgres_server
      expect { nx.start }.to nap(5)
    end

    it "registers deadline and hops" do
      postgres_server.vm.strand.update(label: "wait")
      expect { nx.start }.to hop("refresh_dns_record")
      expect(Semaphore.where(strand_id: st.id, name: "initial_provisioning").first).to exist
    end

    it "buds trigger_pg_current_xact_id_on_parent if it has parent" do
      postgres_server.vm.strand.update(label: "wait")
      parent = create_postgres_resource(project:, name: "pg-parent-resource")
      create_postgres_server(resource: parent, server_index: 1)
      postgres_resource.update(parent:)
      expect { nx.start }.to hop("refresh_dns_record")
      expect(st.children.count).to eq(1)
      expect(st.children.first.label).to eq("trigger_pg_current_xact_id_on_parent")
    end
  end

  describe "#trigger_pg_current_xact_id_on_parent" do
    it "triggers pg_current_xact_id and pops" do
      parent = create_postgres_resource(project:, name: "pg-parent-resource")
      create_postgres_server(resource: parent, server_index: 1)
      postgres_resource.update(parent:)

      fresh_nx = described_class.new(st)
      parent_sshable = fresh_nx.postgres_resource.parent.representative_server.vm.sshable
      expect(parent_sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", hash_including(:stdin)).and_return("1234")

      expect { fresh_nx.trigger_pg_current_xact_id_on_parent }.to exit({"msg" => "triggered pg_current_xact_id"})
    end
  end

  describe "#refresh_dns_record" do
    it "creates dns records and hops" do
      postgres_server
      expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
      dns_zone = DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")
      nx.incr_initial_provisioning

      dns_zone.insert_record(record_name: "pg-test-resource.pg.example.com.", type: "A", ttl: 10, data: "2.3.4.5")
      dns_zone.insert_record(record_name: "pg-test-resource.pg.example.com.", type: "AAAA", ttl: 10, data: "2::1")
      dns_zone.insert_record(record_name: "private.pg-test-resource.pg.example.com.", type: "A", ttl: 10, data: "127.0.0.1")
      dns_zone.insert_record(record_name: "private.pg-test-resource.pg.example.com.", type: "AAAA", ttl: 10, data: "::1")
      DnsRecord.where(dns_zone_id: dns_zone.id).update(created_at: Time.now - 10)

      expect { nx.refresh_dns_record }.to hop("initialize_certificates")

      ds = DnsRecord.where(dns_zone_id: dns_zone.id)
        .exclude(:tombstoned)
        .distinct(:name, :type)
        .reverse(:name, :type, :created_at)
      expect(ds.select_map([:type, :name, :data])).to eq [
        ["AAAA", "private.pg-test-resource.pg.example.com.", postgres_server.vm.private_ipv6_string],
        ["A", "private.pg-test-resource.pg.example.com.", postgres_server.vm.private_ipv4_string],
        ["AAAA", "pg-test-resource.pg.example.com.", postgres_server.vm.ip6_string],
        ["A", "pg-test-resource.pg.example.com.", postgres_server.vm.ip4_string]
      ]
      expect(DnsRecord.where(dns_zone_id: dns_zone.id).where(:tombstoned).select_order_map([:type, :name, :data])).to eq [
        ["A", "pg-test-resource.pg.example.com.", "2.3.4.5"],
        ["A", "private.pg-test-resource.pg.example.com.", "127.0.0.1"],
        ["AAAA", "pg-test-resource.pg.example.com.", "2::1"],
        ["AAAA", "private.pg-test-resource.pg.example.com.", "::1"]
      ]
    end

    it "does not create public AAAA record for older resources" do
      postgres_server.resource.update(created_at: Time.utc(2026, 1, 13, 19))
      expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
      dns_zone = DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")
      nx.incr_initial_provisioning
      expect { nx.refresh_dns_record }.to hop("initialize_certificates")
      expect(DnsRecord.where(dns_zone_id: dns_zone.id).select_order_map([:type, :name])).to eq [
        ["A", "pg-test-resource.pg.example.com."],
        ["A", "private.pg-test-resource.pg.example.com."],
        ["AAAA", "private.pg-test-resource.pg.example.com."]
      ]
    end

    it "updates public AAAA record if it already exists for older resources" do
      postgres_server.resource.update(created_at: Time.utc(2026, 1, 13, 19))
      expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
      dns_zone = DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")
      dns_zone.insert_record(record_name: postgres_server.resource.hostname, type: "AAAA", ttl: 10, data: "::1")
      DnsRecord.where(dns_zone_id: dns_zone.id).update(created_at: Time.now - 60)
      nx.incr_initial_provisioning
      expect { nx.refresh_dns_record }.to hop("initialize_certificates")
      DnsRecord.where(dns_zone_id: dns_zone.id).where { created_at < Time.now - 10 }.destroy
      expect(DnsRecord.where(dns_zone_id: dns_zone.id).exclude(:tombstoned).select_order_map([:type, :name])).to eq [
        ["A", "pg-test-resource.pg.example.com."],
        ["A", "private.pg-test-resource.pg.example.com."],
        ["AAAA", "pg-test-resource.pg.example.com."],
        ["AAAA", "private.pg-test-resource.pg.example.com."]
      ]
    end

    it "creates CNAME DNS records for AWS instances" do
      postgres_server
      AwsInstance.create_with_id(postgres_server.vm, ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com")
      postgres_resource.location.update(provider: "aws")
      expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
      dns_zone = DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")
      nx.incr_initial_provisioning
      expect { nx.refresh_dns_record }.to hop("initialize_certificates")
      expect(DnsRecord.where(dns_zone_id: dns_zone.id).select_order_map([:type, :name])).to eq [["CNAME", "pg-test-resource.pg.example.com."]]
    end

    it "skips public AAAA but creates private AAAA for GCP instances without ephemeral_net6" do
      postgres_server
      postgres_server.vm.update(ephemeral_net6: nil)
      postgres_resource.location.update(provider: "gcp")
      expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
      dns_zone = DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")
      nx.incr_initial_provisioning
      expect { nx.refresh_dns_record }.to hop("initialize_certificates")
      expect(DnsRecord.where(dns_zone_id: dns_zone.id).exclude(:tombstoned).select_order_map([:type, :name])).to eq [
        ["A", "pg-test-resource.pg.example.com."],
        ["A", "private.pg-test-resource.pg.example.com."],
        ["AAAA", "private.pg-test-resource.pg.example.com."]
      ]
    end

    it "hops even if dns zone is not configured" do
      postgres_server
      expect { nx.refresh_dns_record }.to hop("wait")
    end

    it "hops to wait if initial_provisioning is not set even with dns zone" do
      postgres_server
      expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
      DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")
      expect { nx.refresh_dns_record }.to hop("wait")
    end
  end

  describe "#initialize_certificates" do
    it "hops to wait_servers after creating certificates" do
      pr = create_postgres_resource(with_certs: false)
      Firewall.create(name: "#{pr.ubid}-internal-firewall", location_id:, project: postgres_project)
      expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
      DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")

      init_nx = described_class.new(pr.strand)
      expect { init_nx.initialize_certificates }.to hop("wait_servers")
      pr.reload
      expect(pr.root_cert_1).not_to be_nil
      expect(pr.root_cert_2).not_to be_nil
      expect(pr.server_cert).not_to be_nil
    end

    it "naps if there are children" do
      DnsZone.create(project_id: postgres_project.id, name: "postgres.ubicloud.com")
      expect(Config).to receive(:postgres_service_hostname).and_return("postgres.ubicloud.com").at_least(:once)
      st.update(label: "initialize_certificates")
      Strand.create(parent: st, prog: "Postgres::PostgresResourceNexus", label: "trigger_pg_current_xact_id_on_parent", lease: Time.now + 10)
      expect { nx.initialize_certificates }.to nap(5)
    end
  end

  describe "#refresh_certificates" do
    it "rotates root certificate if root_cert_1 is close to expiration" do
      postgres_server
      short_cert_pem, short_key_pem = Util.create_root_certificate(common_name: "Test Root CA", duration: 60 * 60 * 24 * 30 * 4)
      postgres_resource.update(root_cert_1: short_cert_pem, root_cert_key_1: short_key_pem)

      expect { nx.refresh_certificates }.to hop("wait")
      expect(Semaphore.where(strand_id: postgres_server.strand.id, name: "refresh_certificates").first).to exist
    end
  end

  describe "#refresh_certificates", "with dns_zone" do
    before do
      DnsZone.create(project_id: postgres_project.id, name: "postgres.ubicloud.com")
      allow(Config).to receive(:postgres_service_hostname).and_return("postgres.ubicloud.com")
    end

    it "rotates server certificate if it is close to expiration" do
      postgres_server
      short_cert_pem, short_key_pem = Util.create_certificate(
        subject: "/CN=Test Server",
        extensions: ["keyUsage=digitalSignature"],
        duration: 60 * 60 * 24 * 29,
        issuer_cert: OpenSSL::X509::Certificate.new(postgres_resource.root_cert_1),
        issuer_key: OpenSSL::PKey::EC.new(postgres_resource.root_cert_key_1)
      ).map(&:to_pem)
      postgres_resource.update(server_cert: short_cert_pem, server_cert_key: short_key_pem)

      expect { nx.refresh_certificates }.to hop("wait")
      expect(Semaphore.where(strand_id: postgres_server.strand.id, name: "refresh_certificates").first).to exist
    end

    it "rotates server certificate if refresh_certificate semaphore is set" do
      postgres_server
      nx.incr_refresh_certificates

      expect { nx.refresh_certificates }.to hop("wait")
      expect(Semaphore.where(strand_id: postgres_server.strand.id, name: "refresh_certificates").first).to exist
    end

    it "rotates server certificate using root_cert_2 if root_cert_1 is close to expiration" do
      postgres_server
      short_cert_pem, short_key_pem = Util.create_root_certificate(common_name: "Test Root CA", duration: 60 * 60 * 24 * 360)
      short_server_cert_pem, short_server_key_pem = Util.create_certificate(
        subject: "/CN=Test Server",
        extensions: ["keyUsage=digitalSignature"],
        duration: 60 * 60 * 24 * 29,
        issuer_cert: OpenSSL::X509::Certificate.new(postgres_resource.root_cert_1),
        issuer_key: OpenSSL::PKey::EC.new(postgres_resource.root_cert_key_1)
      ).map(&:to_pem)
      postgres_resource.update(root_cert_1: short_cert_pem, root_cert_key_1: short_key_pem, server_cert: short_server_cert_pem, server_cert_key: short_server_key_pem)

      expect { nx.refresh_certificates }.to hop("wait")
      expect(Semaphore.where(strand_id: postgres_server.strand.id, name: "refresh_certificates").first).to exist
    end
  end

  describe "#wait_servers" do
    it "naps if server not ready" do
      postgres_server
      expect { nx.wait_servers }.to nap(5)
    end

    it "hops if server is ready" do
      postgres_server.strand.update(label: "wait")
      expect { nx.wait_servers }.to hop("update_billing_records")
    end
  end

  describe "#update_billing_records" do
    it "skips to wait if project is not billable" do
      postgres_server
      project.update(billable: false)
      expect { nx.update_billing_records }.to hop("wait")
      expect(BillingRecord.where(resource_id: postgres_resource.id)).to be_empty
    end

    it "creates billing record for cores and storage then hops" do
      postgres_server
      project.update(billable: true)

      expect { nx.update_billing_records }.to hop("wait")
      expect(BillingRecord.where(resource_id: postgres_resource.id).count).to eq(2)
    end

    it "creates standby billing records for HA enabled resources" do
      postgres_server
      postgres_resource.update(ha_type: "async")
      project.update(billable: true)

      expect { nx.update_billing_records }.to hop("wait")
      # 2 primary records (VCpu + Storage) + 2 standby records (StandbyVCpu + StandbyStorage) = 4 total
      billing_records = BillingRecord.where(resource_id: postgres_resource.id).all
      expect(billing_records.count).to eq(4)
      # Check billing rates include standby types
      resource_types = billing_records.map { it.billing_rate["resource_type"] }
      expect(resource_types).to include("PostgresStandbyVCpu", "PostgresStandbyStorage")
    end

    it "does not recreate billing records when they match existing records" do
      postgres_server
      project.update(billable: true)

      vcpu_rate_id = BillingRate.from_resource_properties("PostgresVCpu", "standard-standard", "hetzner-fsn1", false)["id"]
      storage_rate_id = BillingRate.from_resource_properties("PostgresStorage", "standard", "hetzner-fsn1", false)["id"]
      br_vcpu = BillingRecord.create(
        project_id: project.id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: vcpu_rate_id,
        amount: 2
      )
      br_storage = BillingRecord.create(
        project_id: project.id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: storage_rate_id,
        amount: 64
      )

      expect { nx.update_billing_records }.to hop("wait")

      expect(br_vcpu.reload.span.end).to be_nil
      expect(br_storage.reload.span.end).to be_nil
      expect(BillingRecord.where(resource_id: postgres_resource.id).count).to eq(2)
    end

    it "finalizes old and creates new billing records when amount changes" do
      postgres_server
      project.update(billable: true)

      past_span = Sequel.pg_range((Time.now - 3600)..)
      vcpu_rate_id = BillingRate.from_resource_properties("PostgresVCpu", "standard-standard", "hetzner-fsn1", false)["id"]
      storage_rate_id = BillingRate.from_resource_properties("PostgresStorage", "standard", "hetzner-fsn1", false)["id"]
      br_vcpu = BillingRecord.create(
        project_id: project.id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: vcpu_rate_id,
        amount: 4,
        span: past_span
      )
      br_storage = BillingRecord.create(
        project_id: project.id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: storage_rate_id,
        amount: 128,
        span: past_span
      )

      expect { nx.update_billing_records }.to hop("wait")

      expect(br_vcpu.reload.span.end).not_to be_nil
      expect(br_storage.reload.span.end).not_to be_nil

      active_records = postgres_resource.active_billing_records
      expect(active_records.count).to eq(2)
      expect(active_records.map(&:amount).sort).to eq([2, 64])
    end
  end

  describe "#wait" do
    it "hops to update_billing_records when update_billing_records is set" do
      nx.incr_update_billing_records
      expect { nx.wait }.to hop("update_billing_records")
    end

    it "hops to refresh_dns_record when refresh_dns_record is set" do
      nx.incr_refresh_dns_record
      expect { nx.wait }.to hop("refresh_dns_record")
    end

    it "hops to refresh_certificates if the certificate is checked more than 1 months ago" do
      postgres_resource.update(certificate_last_checked_at: Time.now - 60 * 60 * 24 * 30 - 1)
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to refresh_certificates when refresh_certificates is set" do
      nx.incr_refresh_certificates
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "calls set_firewall_rules method of the postgres resource when update_firewall_rules is set" do
      nx.incr_update_firewall_rules
      expect { nx.wait }.to nap(30)
      expect(Semaphore.where(strand_id: st.id, name: "update_firewall_rules")).to be_empty
    end

    it "if not read_replica and promote is set, just naps" do
      nx.incr_promote
      expect { nx.wait }.to nap(30)
      expect(Semaphore.where(strand_id: st.id, name: "promote")).to be_empty
    end

    it "calls handle_storage_auto_scale when check_disk_usage is set and decrements the semaphore" do
      nx.incr_check_disk_usage
      expect(nx.postgres_resource).to receive(:handle_storage_auto_scale)
      expect { nx.wait }.to nap(30)
      expect(Semaphore.where(strand_id: st.id, name: "check_disk_usage")).to be_empty
    end
  end

  describe "#wait", "with postgres_server" do
    before do
      postgres_server.strand.update(label: "wait")
    end

    it "buds ConvergePostgresResource prog if needs_convergence? is true" do
      postgres_server.incr_recycle
      expect { nx.wait }.to nap(30)
      expect(st.children_dataset.where(prog: "Postgres::ConvergePostgresResource").first).to exist
    end

    it "if read_replica and promote is set, promotes and naps" do
      parent = create_postgres_resource(project:, name: "pg-parent-resource")
      create_postgres_server(resource: parent, server_index: 1)
      postgres_resource.update(parent:)
      nx.incr_promote
      expect { nx.wait }.to nap(30)
      expect(postgres_resource.reload.parent_id).to be_nil
      expect(Semaphore.where(strand_id: postgres_server.strand.id, name: "promote").first).to exist
    end
  end

  describe "#destroy" do
    it "adds destroy semaphore to children and hops to wait_children_destroyed" do
      postgres_server
      st.update(label: "destroy")
      child_st = Strand.create(prog: "Postgres::ConvergePostgresResource", label: "start", parent: st)
      nx.incr_destroy
      expect { nx.destroy }.to hop("wait_children_destroyed")
      expect(Semaphore.where(name: "destroy").select_order_map(:strand_id)).to eq [child_st.id]
    end
  end

  describe "#wait_children_destroyed" do
    it "naps if children still exist" do
      postgres_server
      st.update(label: "wait_children_destroyed")
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "start", parent: st)
      expect { nx.wait_children_destroyed }.to nap(5)
    end

    context "with internal firewall" do
      before do
        Firewall.create(name: "#{postgres_resource.ubid}-internal-firewall", location_id:, project: postgres_project)
      end

      it "triggers server deletion and waits until it is deleted" do
        postgres_server
        expect(Config).to receive(:postgres_service_hostname).and_return("pg.example.com").at_least(:once)
        DnsZone.create(project_id: postgres_project.id, name: "pg.example.com")

        expect { nx.wait_children_destroyed }.to exit({"msg" => "postgres resource is deleted"})
        expect(Semaphore.where(strand_id: postgres_server.strand.id, name: "destroy").first).to exist
        expect(postgres_resource).not_to exist
      end

      it "completes destroy even if dns zone is not configured" do
        postgres_server
        expect { nx.wait_children_destroyed }.to exit({"msg" => "postgres resource is deleted"})
        expect(postgres_resource).not_to exist
      end

      it "does not destroy timelines (retained for 10-day recovery)" do
        postgres_server
        expect { nx.wait_children_destroyed }.to exit({"msg" => "postgres resource is deleted"})
        expect(Semaphore.where(strand_id: postgres_server.timeline.strand.id, name: "destroy").count).to eq(0)
      end
    end
  end
end
