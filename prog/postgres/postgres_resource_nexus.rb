# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresResourceNexus < Prog::Base
  subject_is :postgres_resource

  extend Forwardable
  def_delegators :postgres_resource, :servers, :representative_server

  semaphore :update_firewall_rules, :refresh_dns_record, :destroy

  def self.assemble(project_id:, location:, name:, target_vm_size:, target_storage_size_gib:, ha_type: PostgresResource::HaType::NONE, parent_id: nil, restore_target: nil)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    Validation.validate_location(location, project.provider)
    Validation.validate_name(name)
    Validation.validate_vm_size(target_vm_size)
    Validation.validate_postgres_ha_type(ha_type)

    DB.transaction do
      superuser_password, timeline_id, timeline_access = if parent_id.nil?
        [SecureRandom.urlsafe_base64(15), Prog::Postgres::PostgresTimelineNexus.assemble.id, "push"]
      else
        unless (parent = PostgresResource[parent_id])
          fail "No existing parent"
        end
        restore_target = Validation.validate_date(restore_target, "restore_target")
        parent.timeline.refresh_earliest_backup_completion_time
        unless (earliest_restore_time = parent.timeline.earliest_restore_time) && earliest_restore_time <= restore_target &&
            parent.timeline.latest_restore_time && restore_target <= parent.timeline.latest_restore_time
          fail Validation::ValidationFailed.new({restore_target: "Restore target must be between #{earliest_restore_time} and #{parent.timeline.latest_restore_time}"})
        end
        [parent.superuser_password, parent.timeline.id, "fetch"]
      end

      postgres_resource = PostgresResource.create_with_id(
        project_id: project_id, location: location, name: name,
        target_vm_size: target_vm_size, target_storage_size_gib: target_storage_size_gib,
        superuser_password: superuser_password, ha_type: ha_type, parent_id: parent_id,
        restore_target: restore_target,
        hostname_version: "v2"
      )
      postgres_resource.associate_with_project(project)

      PostgresFirewallRule.create_with_id(postgres_resource_id: postgres_resource.id, cidr: "0.0.0.0/0")

      Prog::Postgres::PostgresServerNexus.assemble(resource_id: postgres_resource.id, timeline_id: timeline_id, timeline_access: timeline_access, representative_at: Time.now)
      postgres_resource.required_standby_count.times do
        Prog::Postgres::PostgresServerNexus.assemble(resource_id: postgres_resource.id, timeline_id: timeline_id, timeline_access: "fetch")
      end

      Strand.create(prog: "Postgres::PostgresResourceNexus", label: "start") { _1.id = postgres_resource.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        postgres_resource.active_billing_records.each(&:finalize)
        hop_destroy
      end
    end
  end

  label def start
    nap 5 unless representative_server.vm.strand.label == "wait"
    register_deadline(:wait, 10 * 60)
    bud self.class, frame, :trigger_pg_current_xact_id_on_parent if postgres_resource.parent
    hop_refresh_dns_record
  end

  label def trigger_pg_current_xact_id_on_parent
    postgres_resource.parent.representative_server.run_query("SELECT pg_current_xact_id()")
    pop "triggered pg_current_xact_id"
  end

  label def refresh_dns_record
    decr_refresh_dns_record

    Prog::Postgres::PostgresResourceNexus.dns_zone&.delete_record(record_name: postgres_resource.hostname)
    Prog::Postgres::PostgresResourceNexus.dns_zone&.insert_record(record_name: postgres_resource.hostname, type: "A", ttl: 10, data: representative_server.vm.ephemeral_net4.to_s)

    hop_initialize_certificates
  end

  label def initialize_certificates
    # Each root will be valid for 10 years and will be used to generate server
    # certificates between its 4th and 9th years. To simulate this behaviour
    # without excessive branching, we create the very first root certificate
    # with only 5 year validity. So it would look like it is created 5 years
    # ago.
    postgres_resource.root_cert_1, postgres_resource.root_cert_key_1 = Util.create_root_certificate(common_name: "#{postgres_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
    postgres_resource.root_cert_2, postgres_resource.root_cert_key_2 = Util.create_root_certificate(common_name: "#{postgres_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
    postgres_resource.server_cert, postgres_resource.server_cert_key = create_certificate
    postgres_resource.save_changes

    reap
    hop_wait_servers if leaf?
    nap 5
  end

  label def refresh_certificates
    # We stop using root_cert_1 to sign server certificates at the beginning
    # of 9th year of its validity. However it is possible that it is used to
    # sign a server just at the beginning of the 9 year mark, thus it needs
    # to be in the list of trusted roots until that server certificate expires.
    # 10 year - (9 year + 6 months) - (1 month padding) = 5 months. So we will
    # rotate the root_cert_1 with root_cert_2 if the remaining time is less
    # than 5 months.
    if OpenSSL::X509::Certificate.new(postgres_resource.root_cert_1).not_after < Time.now + 60 * 60 * 24 * 30 * 5
      postgres_resource.root_cert_1, postgres_resource.root_cert_key_1 = postgres_resource.root_cert_2, postgres_resource.root_cert_key_2
      postgres_resource.root_cert_2, postgres_resource.root_cert_key_2 = Util.create_root_certificate(common_name: "#{postgres_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
      servers.each(&:incr_refresh_certificates)
    end

    if OpenSSL::X509::Certificate.new(postgres_resource.server_cert).not_after < Time.now + 60 * 60 * 24 * 30
      postgres_resource.server_cert, postgres_resource.server_cert_key = create_certificate
      servers.each(&:incr_refresh_certificates)
    end

    postgres_resource.certificate_last_checked_at = Time.now
    postgres_resource.save_changes

    hop_wait
  end

  label def wait_servers
    nap 5 if servers.any? { _1.strand.label != "wait" }
    hop_create_billing_record
  end

  label def create_billing_record
    billing_record_parts = []
    (postgres_resource.required_standby_count + 1).times do |index|
      billing_record_parts.push({resource_type: index.zero? ? "PostgresCores" : "PostgresStandbyCores", amount: representative_server.vm.cores})
      billing_record_parts.push({resource_type: index.zero? ? "PostgresStorage" : "PostgresStandbyStorage", amount: postgres_resource.target_storage_size_gib})
    end

    billing_record_parts.each do |brp|
      BillingRecord.create_with_id(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.name,
        billing_rate_id: BillingRate.from_resource_properties(brp[:resource_type], "standard", postgres_resource.location)["id"],
        amount: brp[:amount]
      )
    end

    hop_wait
  end

  label def wait
    # Create missing standbys
    (postgres_resource.required_standby_count + 1 - postgres_resource.servers.count).times do
      Prog::Postgres::PostgresServerNexus.assemble(resource_id: postgres_resource.id, timeline_id: postgres_resource.timeline.id, timeline_access: "fetch")
    end

    when_refresh_dns_record_set? do
      hop_refresh_dns_record
    end

    if postgres_resource.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    when_update_firewall_rules_set? do
      postgres_resource.representative_server.incr_update_firewall_rules
      decr_update_firewall_rules
    end

    nap 30
  end

  label def destroy
    register_deadline(nil, 5 * 60)

    decr_destroy

    strand.children.each { _1.destroy }
    unless servers.empty?
      servers.each(&:incr_destroy)
      nap 5
    end

    Prog::Postgres::PostgresResourceNexus.dns_zone&.delete_record(record_name: postgres_resource.hostname)
    postgres_resource.dissociate_with_project(postgres_resource.project)
    postgres_resource.destroy

    pop "postgres resource is deleted"
  end

  def create_certificate
    root_cert = OpenSSL::X509::Certificate.new(postgres_resource.root_cert_1)
    root_cert_key = OpenSSL::PKey::EC.new(postgres_resource.root_cert_key_1)
    if root_cert.not_after < Time.now + 60 * 60 * 24 * 365 * 1
      root_cert = OpenSSL::X509::Certificate.new(postgres_resource.root_cert_2)
      root_cert_key = OpenSSL::PKey::EC.new(postgres_resource.root_cert_key_2)
    end

    Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{postgres_resource.identity}",
      extensions: ["subjectAltName=DNS:#{postgres_resource.identity},DNS:#{postgres_resource.hostname}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth,clientAuth"],
      duration: 60 * 60 * 24 * 30 * 6, # ~6 months
      issuer_cert: root_cert,
      issuer_key: root_cert_key
    ).map(&:to_pem)
  end

  def self.dns_zone
    @@dns_zone ||= DnsZone[project_id: Config.postgres_service_project_id, name: Config.postgres_service_hostname]
  end
end
