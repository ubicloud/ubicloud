# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresResourceNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77") }

  let(:postgres_resource) {
    instance_double(
      PostgresResource,
      ubid: "pgnjbsrja7ka4nk7ptcg03szg2",
      location_id: Location::HETZNER_FSN1_ID,
      root_cert_1: "root cert 1",
      root_cert_key_1: nil,
      root_cert_2: "root cert 2",
      root_cert_key_2: nil,
      server_cert: "server cert",
      server_cert_key: nil,
      parent: nil,
      servers: [instance_double(
        PostgresServer,
        vm_id: Vm.generate_uuid,
        vm: instance_double(
          Vm,
          family: "standard",
          vcpus: 2,
          private_subnets: [instance_double(PrivateSubnet, id: "627a23ee-c1fb-86d9-a261-21cc48415916")],
          display_state: "running"
        )
      )],
      representative_server: instance_double(
        PostgresServer,
        vm: instance_double(
          Vm,
          family: "standard",
          vcpus: 2,
          private_subnets: [instance_double(PrivateSubnet, id: "627a23ee-c1fb-86d9-a261-21cc48415916")]
        )
      ),
      private_subnet: instance_double(PrivateSubnet)
    ).as_null_object
  }

  before do
    allow(nx).to receive(:postgres_resource).and_return(postgres_resource)
  end

  describe ".assemble" do
    let(:customer_project) { Project.create(name: "default") }
    let(:postgres_project) { Project.create(name: "default") }
    let(:private_location) {
      loc = Location.create(
        name: "us-west-2",
        display_name: "aws-us-west-2",
        ui_name: "aws-us-west-2",
        visible: true,
        provider: "aws",
        project_id: postgres_project.id
      )
      LocationCredential.create(
        access_key: "access-key-id",
        secret_key: "secret-access-key"
      ) { it.id = loc.id }
      loc
    }

    it "validates input" do
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)

      expect {
        described_class.assemble(project_id: "26820e05-562a-4e25-a51b-de5f78bd00af", location_id: Location::HETZNER_FSN1_ID, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: nil, name: "pg/server/name", target_vm_size: "standard-2", target_storage_size_gib: 128)
      }.to raise_error RuntimeError, "No existing location"

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128)
      }.not_to raise_error

      expect {
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: "69c0f4cd-99c1-8ed0-acfe-7b013ce2fa0b")
      }.to raise_error RuntimeError, "No existing parent"

      private_location.update(project_id: customer_project.id)
      described_class.assemble(project_id: customer_project.id, location_id: private_location.id, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 118)

      expect {
        parent = described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-parent-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject
        expect(PostgresResource).to receive(:[]).with(parent.id).and_return(parent)
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: parent.id, restore_target: Time.now)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: restore_target"
    end

    it "does not allow giving different version than parent for restore" do
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)
      parent = described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-parent-name", target_vm_size: "standard-2", target_storage_size_gib: 128, target_version: "16").subject
      expect(PostgresResource).to receive(:[]).with(parent.id).and_return(parent)
      expect {
        described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: parent.id, target_version: "17", restore_target: Time.now)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: version"
    end

    it "passes timeline of parent resource if parent is passed" do
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)

      parent = described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject
      restore_target = Time.now
      expect(parent.timeline).to receive(:earliest_restore_time).and_return(restore_target - 10 * 60)
      expect(PostgresResource).to receive(:[]).with(parent.id).and_return(parent)
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(timeline_id: parent.timeline.id, timeline_access: "fetch")).and_return(instance_double(Strand, subject: postgres_resource.representative_server))

      described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name-2", target_vm_size: "standard-2", target_storage_size_gib: 128, parent_id: parent.id, restore_target: restore_target)
    end

    it "creates internal firewall and customer private subnet and firewall" do
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)
      pg = described_class.assemble(project_id: customer_project.id, location_id: Location::HETZNER_FSN1_ID, name: "pg-name", target_vm_size: "standard-2", target_storage_size_gib: 128).subject

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
  end

  describe "#before_run" do
    it "hops to destroy and stops billing records when needed" do
      br = instance_double(BillingRecord)
      expect(br).to receive(:finalize).twice
      expect(postgres_resource).to receive(:active_billing_records).and_return([br, br])
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect(postgres_resource.representative_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "registers deadline and hops" do
      expect(postgres_resource.representative_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(nx).to receive(:register_deadline)
      expect { nx.start }.to hop("refresh_dns_record")
    end

    it "buds trigger_pg_current_xact_id_on_parent if it has parent" do
      expect(postgres_resource.representative_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(nx).to receive(:register_deadline)
      expect(postgres_resource).to receive(:parent).and_return(instance_double(PostgresResource))
      expect(nx).to receive(:bud).with(described_class, {}, :trigger_pg_current_xact_id_on_parent)
      expect { nx.start }.to hop("refresh_dns_record")
    end
  end

  describe "#trigger_pg_current_xact_id_on_parent" do
    it "triggers pg_current_xact_id and pops" do
      representative_server = instance_double(PostgresServer)
      expect(representative_server).to receive(:run_query).with("SELECT pg_current_xact_id()")
      expect(postgres_resource).to receive(:parent).and_return(instance_double(PostgresResource, representative_server: representative_server))

      expect { nx.trigger_pg_current_xact_id_on_parent }.to exit({"msg" => "triggered pg_current_xact_id"})
    end
  end

  describe "#refresh_dns_record" do
    before do
      allow(postgres_resource).to receive(:location).and_return(instance_double(Location, aws?: false))
      allow(postgres_resource.representative_server.vm).to receive(:ip4_string).and_return("1.1.1.1")
    end

    it "creates dns records and hops" do
      expect(postgres_resource).to receive(:hostname).and_return("pg-name.postgres.ubicloud.com.").twice
      dns_zone = instance_double(DnsZone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "pg-name.postgres.ubicloud.com.")
      expect(dns_zone).to receive(:insert_record).with(record_name: "pg-name.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.1.1.1")
      expect(postgres_resource).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect { nx.refresh_dns_record }.to hop("initialize_certificates")
    end

    it "creates CNAME DNS records for AWS instances" do
      expect(postgres_resource).to receive(:location).and_return(instance_double(Location, aws?: true))
      expect(postgres_resource.representative_server.vm).to receive(:aws_instance).and_return(instance_double(AwsInstance, ipv4_dns_name: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com"))
      expect(postgres_resource).to receive(:hostname).and_return("pg-name.postgres.ubicloud.com.").twice
      dns_zone = instance_double(DnsZone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "pg-name.postgres.ubicloud.com.")
      expect(dns_zone).to receive(:insert_record).with(record_name: "pg-name.postgres.ubicloud.com.", type: "CNAME", ttl: 10, data: "ec2-44-224-119-46.us-west-2.compute.amazonaws.com.")
      expect(postgres_resource).to receive(:dns_zone).and_return(dns_zone).at_least(:once)
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect { nx.refresh_dns_record }.to hop("initialize_certificates")
    end

    it "hops even if dns zone is not configured" do
      expect(postgres_resource).to receive(:dns_zone).and_return(nil).at_least(:once)
      expect { nx.refresh_dns_record }.to hop("wait")
    end

    it "hops to wait if initial_provisioning is not set" do
      expect(postgres_resource).to receive(:dns_zone).and_return(nil).at_least(:once)
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect { nx.refresh_dns_record }.to hop("wait")
    end
  end

  describe "#initialize_certificates" do
    it "hops to wait_servers after creating certificates" do
      project = Project.create(name: "default")
      postgres_resource = PostgresResource.create(
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name: "pg-name",
        target_vm_size: "standard-2",
        target_storage_size_gib: 128,
        superuser_password: "dummy-password",
        target_version: "16"
      )

      expect(nx).to receive(:postgres_resource).and_return(postgres_resource).at_least(:once)
      expect(postgres_resource).to receive(:dns_zone).and_return("something").at_least(:once)

      expect(Util).to receive(:create_root_certificate).with(duration: 60 * 60 * 24 * 365 * 5, common_name: "#{postgres_resource.ubid} Root Certificate Authority").and_call_original
      expect(Util).to receive(:create_root_certificate).with(duration: 60 * 60 * 24 * 365 * 10, common_name: "#{postgres_resource.ubid} Root Certificate Authority").and_call_original
      expect(nx).to receive(:create_certificate).and_call_original

      expect { nx.initialize_certificates }.to hop("wait_servers")
    end

    it "naps if there are children" do
      st.update(prog: "Postgres::PostgresResourceNexus", label: "initialize_certificates", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Postgres::PostgresResourceNexus", label: "trigger_pg_current_xact_id_on_parent", stack: [{}], lease: Time.now + 10)
      expect(Util).to receive(:create_root_certificate).twice
      expect(nx).to receive(:create_certificate)
      expect { nx.initialize_certificates }.to nap(5)
    end
  end

  describe "#refresh_certificates" do
    it "rotates root certificate if root_cert_1 is close to expiration" do
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 30 * 4))
      expect(OpenSSL::X509::Certificate).to receive(:new).with("server cert").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 30 * 4))

      expect(Util).to receive(:create_root_certificate).with(duration: 60 * 60 * 24 * 365 * 10, common_name: "#{postgres_resource.ubid} Root Certificate Authority")
      expect(postgres_resource.servers).to all(receive(:incr_refresh_certificates))

      expect { nx.refresh_certificates }.to hop("wait")
    end

    it "rotates server certificate if it is close to expiration" do
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 365 * 4))
      expect(OpenSSL::X509::Certificate).to receive(:new).with("server cert").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 29))

      expect(nx).to receive(:create_certificate)
      expect(postgres_resource.servers).to all(receive(:incr_refresh_certificates))

      expect { nx.refresh_certificates }.to hop("wait")
    end

    it "rotates server certificate if refresh_certificate semaphore is set" do
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 365 * 4))
      expect(OpenSSL::X509::Certificate).to receive(:new).with("server cert").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 365 * 4))

      expect(nx).to receive(:create_certificate)
      expect(nx).to receive(:when_refresh_certificates_set?).and_yield
      expect(postgres_resource.servers).to all(receive(:incr_refresh_certificates))

      expect { nx.refresh_certificates }.to hop("wait")
    end

    it "rotates server certificate using root_cert_2 if root_cert_1 is close to expiration" do
      root_cert_2 = instance_double(OpenSSL::X509::Certificate)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").twice.and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 360))
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 2").and_return(root_cert_2)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("server cert").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 29))

      expect(Util).to receive(:create_certificate).with(hash_including(issuer_cert: root_cert_2)).and_return([instance_double(OpenSSL::X509::Certificate, to_pem: "server cert")])
      expect(postgres_resource.servers).to all(receive(:incr_refresh_certificates))

      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#wait_servers" do
    it "naps if server not ready" do
      expect(postgres_resource.servers).to all(receive(:strand).and_return(instance_double(Strand, label: "start")))

      expect { nx.wait_servers }.to nap(5)
    end

    it "hops if server is ready" do
      expect(postgres_resource.servers).to all(receive(:strand).and_return(instance_double(Strand, label: "wait")))
      expect { nx.wait_servers }.to hop("update_billing_records")
    end
  end

  describe "#update_billing_records" do
    it "skips to wait if project is not billable" do
      non_billable_project = Project.create(name: "default", billable: false)
      expect(postgres_resource).to receive(:project).and_return(non_billable_project).at_least(:once)
      expect(postgres_resource.project.billable).to be false
      expect(BillingRecord).not_to receive(:create)
      expect { nx.update_billing_records }.to hop("wait")
    end

    it "creates billing record for cores and storage then hops" do
      billable_project = Project.create(name: "default", billable: true)
      expect(postgres_resource).to receive(:project).and_return(billable_project).at_least(:once)
      expect(postgres_resource.project.billable).to be true
      expect(postgres_resource).to receive(:flavor).and_return("standard")
      expect(postgres_resource.representative_server).to receive(:storage_size_gib).and_return(128)
      expect(postgres_resource).to receive(:target_server_count).and_return(2)

      expect(BillingRecord).to receive(:create).with(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresVCpu", "standard-standard", Location[postgres_resource.location_id].name)["id"],
        amount: postgres_resource.representative_server.vm.vcpus
      )

      expect(BillingRecord).to receive(:create).with(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresStandbyVCpu", "standard-standard", Location[postgres_resource.location_id].name)["id"],
        amount: postgres_resource.representative_server.vm.vcpus
      )

      expect(BillingRecord).to receive(:create).with(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresStorage", "standard", Location[postgres_resource.location_id].name)["id"],
        amount: 128
      )

      expect(BillingRecord).to receive(:create).with(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresStandbyStorage", "standard", Location[postgres_resource.location_id].name)["id"],
        amount: 128
      )

      expect { nx.update_billing_records }.to hop("wait")
    end
  end

  describe "#wait" do
    before do
      allow(postgres_resource).to receive_messages(certificate_last_checked_at: Time.now, target_server_count: 1, needs_convergence?: false)
    end

    it "buds ConvergePostgresResource prog if needs_convergence? is true" do
      expect(postgres_resource).to receive(:needs_convergence?).and_return(true)
      expect(nx).to receive(:bud).with(Prog::Postgres::ConvergePostgresResource, {}, :start)
      expect { nx.wait }.to nap(30)
    end

    it "hops to update_billing_records when update_billing_records is set" do
      expect(nx).to receive(:when_update_billing_records_set?).and_yield
      expect { nx.wait }.to hop("update_billing_records")
    end

    it "hops to refresh_dns_record when refresh_dns_record is set" do
      expect(nx).to receive(:when_refresh_dns_record_set?).and_yield
      expect { nx.wait }.to hop("refresh_dns_record")
    end

    it "hops to refresh_certificates if the certificate is checked more than 1 months ago" do
      expect(postgres_resource).to receive(:certificate_last_checked_at).and_return(Time.now - 60 * 60 * 24 * 30 - 1)
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to refresh_certificates when refresh_certificates is set" do
      expect(nx).to receive(:when_refresh_certificates_set?).and_yield
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "calls set_firewall_rules method of the postgres resource when update_firewall_rules is set" do
      expect(nx).to receive(:when_update_firewall_rules_set?).and_yield
      expect(nx).to receive(:decr_update_firewall_rules)
      expect { nx.wait }.to nap(30)
    end

    it "if read_replica and promote is set, promotes and naps" do
      expect(nx).to receive(:when_promote_set?).and_yield
      expect(postgres_resource).to receive(:read_replica?).and_return(true)
      expect(postgres_resource).to receive(:servers).and_return([])
      expect(postgres_resource).to receive(:update).with(parent_id: nil)
      expect(nx).to receive(:decr_promote)
      expect { nx.wait }.to nap(30)
    end

    it "if not read_replica and promote is set, just naps" do
      expect(nx).to receive(:when_promote_set?).and_yield
      expect(postgres_resource).to receive(:read_replica?).and_return(false)
      expect(nx).to receive(:decr_promote)
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "triggers server deletion and waits until it is deleted" do
      dns_zone = instance_double(DnsZone)
      expect(postgres_resource).to receive(:dns_zone).and_return(dns_zone)

      expect(postgres_resource.servers).to all(receive(:incr_destroy))
      expect(postgres_resource.internal_firewall).to receive(:destroy)

      expect(postgres_resource).to receive(:hostname)
      expect(dns_zone).to receive(:delete_record)
      expect(postgres_resource).to receive(:destroy)

      expect(postgres_resource.private_subnet).to receive(:incr_destroy_if_only_used_internally).with(
        ubid: postgres_resource.ubid,
        vm_ids: [postgres_resource.servers.first.vm_id]
      )

      expect { nx.destroy }.to exit({"msg" => "postgres resource is deleted"})
    end

    it "completes destroy even if dns zone is not configured" do
      expect(postgres_resource).to receive(:dns_zone).and_return(nil)
      expect(postgres_resource).to receive(:servers).and_return([]).at_least(:once)
      expect(postgres_resource.private_subnet).to receive(:incr_destroy_if_only_used_internally).with(
        ubid: postgres_resource.ubid,
        vm_ids: []
      )

      expect { nx.destroy }.to exit({"msg" => "postgres resource is deleted"})
    end
  end
end
