# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresResourceNexus < Prog::Base
  subject_is :postgres_resource

  extend Forwardable
  def_delegators :postgres_resource, :server

  semaphore :destroy

  def self.assemble(project_id:, location:, server_name:, target_vm_size:, target_storage_size_gib:, parent_id: nil, restore_target: nil)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    Validation.validate_vm_size(target_vm_size)
    Validation.validate_name(server_name)
    Validation.validate_location(location, project.provider)

    DB.transaction do
      superuser_password, timeline_id, timeline_access = if parent_id.nil?
        [SecureRandom.urlsafe_base64(15), Prog::Postgres::PostgresTimelineNexus.assemble.id, "push"]
      else
        parent = PostgresResource[parent_id]
        [parent.superuser_password, parent.timeline.id, "fetch"]
      end

      postgres_resource = PostgresResource.create_with_id(
        project_id: project_id, location: location, server_name: server_name,
        target_vm_size: target_vm_size, target_storage_size_gib: target_storage_size_gib,
        superuser_password: superuser_password, parent_id: parent_id,
        restore_target: restore_target
      )
      postgres_resource.associate_with_project(project)

      Prog::Postgres::PostgresServerNexus.assemble(resource_id: postgres_resource.id, timeline_id: timeline_id, timeline_access: timeline_access)

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
    nap 5 unless server.vm.strand.label == "wait"
    register_deadline(:wait, 10 * 60)
    hop_create_dns_record
  end

  label def create_dns_record
    dns_zone&.insert_record(record_name: postgres_resource.hostname, type: "A", ttl: 10, data: server.vm.ephemeral_net4.to_s)
    hop_initialize_certificates
  end

  label def initialize_certificates
    # Each root will be valid for 10 years and will be used to generate server
    # certificates between its 4th and 9th years. To simulate this behaviour
    # without excessive branching, we create the very first root certificate
    # with only 5 year validity. So it would look like it is created 5 years
    # ago.
    postgres_resource.root_cert_1, postgres_resource.root_cert_key_1 = create_root_certificate(duration: 60 * 60 * 24 * 365 * 5)
    postgres_resource.root_cert_2, postgres_resource.root_cert_key_2 = create_root_certificate(duration: 60 * 60 * 24 * 365 * 10)
    postgres_resource.server_cert, postgres_resource.server_cert_key = create_server_certificate
    postgres_resource.save_changes

    hop_wait_server
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
      postgres_resource.root_cert_2, postgres_resource.root_cert_key_2 = create_root_certificate(duration: 60 * 60 * 24 * 365 * 10)
      server.incr_refresh_certificates
    end

    if OpenSSL::X509::Certificate.new(postgres_resource.server_cert).not_after < Time.now + 60 * 60 * 24 * 30
      postgres_resource.server_cert, postgres_resource.server_cert_key = create_server_certificate
      server.incr_refresh_certificates
    end

    postgres_resource.certificate_last_checked_at = Time.now
    postgres_resource.save_changes

    hop_wait_server
  end

  label def wait_server
    nap 5 if server.strand.label != "wait"
    hop_create_billing_record
  end

  label def create_billing_record
    BillingRecord.create_with_id(
      project_id: postgres_resource.project_id,
      resource_id: postgres_resource.id,
      resource_name: postgres_resource.server_name,
      billing_rate_id: BillingRate.from_resource_properties("PostgresCores", "standard", postgres_resource.location)["id"],
      amount: server.vm.cores
    )

    BillingRecord.create_with_id(
      project_id: postgres_resource.project_id,
      resource_id: postgres_resource.id,
      resource_name: postgres_resource.server_name,
      billing_rate_id: BillingRate.from_resource_properties("PostgresStorage", "standard", postgres_resource.location)["id"],
      amount: postgres_resource.target_storage_size_gib
    )

    hop_wait
  end

  label def wait
    if postgres_resource.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    nap 30
  end

  label def destroy
    register_deadline(nil, 5 * 60)

    decr_destroy

    unless server.nil?
      server.incr_destroy
      nap 5
    end

    dns_zone&.delete_record(record_name: postgres_resource.hostname)
    postgres_resource.dissociate_with_project(postgres_resource.project)
    postgres_resource.destroy

    pop "postgres resource is deleted"
  end

  def dns_zone
    @@dns_zone ||= DnsZone.where(project_id: Config.postgres_service_project_id, name: Config.postgres_service_hostname).first
  end

  def create_root_certificate(duration:)
    Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{postgres_resource.ubid} Root Certificate Authority",
      extensions: ["basicConstraints=CA:TRUE", "keyUsage=cRLSign,keyCertSign", "subjectKeyIdentifier=hash"],
      duration: duration
    ).map(&:to_pem)
  end

  def create_server_certificate
    root_cert = OpenSSL::X509::Certificate.new(postgres_resource.root_cert_1)
    root_cert_key = OpenSSL::PKey::EC.new(postgres_resource.root_cert_key_1)
    if root_cert.not_after < Time.now + 60 * 60 * 24 * 365 * 1
      root_cert = OpenSSL::X509::Certificate.new(postgres_resource.root_cert_2)
      root_cert_key = OpenSSL::PKey::EC.new(postgres_resource.root_cert_key_2)
    end

    Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{postgres_resource.ubid} Server Certificate",
      extensions: ["subjectAltName=DNS:#{postgres_resource.hostname}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
      duration: 60 * 60 * 24 * 30 * 6, # ~6 months
      issuer_cert: root_cert,
      issuer_key: root_cert_key
    ).map(&:to_pem)
  end
end
