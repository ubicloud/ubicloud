# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresResourceNexus < Prog::Base
  subject_is :postgres_resource

  extend Forwardable
  def_delegators :postgres_resource, :vm

  semaphore :initial_provisioning, :restart, :destroy

  def self.assemble(project_id, location, server_name, vm_size, storage_size_gib)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    Validation.validate_vm_size(vm_size)
    Validation.validate_name(server_name)
    Validation.validate_location(location, project.provider)

    DB.transaction do
      ubid = PostgresResource.generate_ubid

      ssh_key = SshKey.generate
      vm_st = Prog::Vm::Nexus.assemble(
        ssh_key.public_key,
        Config.postgres_service_project_id,
        location: location,
        name: ubid.to_s,
        size: vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30},
          {encrypted: true, size_gib: storage_size_gib}
        ],
        boot_image: "ubuntu-jammy",
        enable_ip4: true
      )

      Sshable.create(
        unix_user: "ubi",
        host: "temp_#{vm_st.id}",
        raw_private_key_1: ssh_key.keypair
      ) { _1.id = vm_st.id }

      postgres_resource = PostgresResource.create(
        project_id: project_id, location: location, server_name: server_name,
        target_vm_size: vm_size, target_storage_size_gib: storage_size_gib,
        superuser_password: SecureRandom.base64(15).gsub(/[+\/]/, "+" => "_", "/" => "-"),
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }
      postgres_resource.associate_with_project(project)

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
    nap 5 unless vm.strand.label == "wait"
    vm.sshable.update(host: vm.ephemeral_net4)

    postgres_resource.incr_initial_provisioning
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline(:wait, 10 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => vm.id, "user" => "ubi"}
    hop_create_dns_record
  end

  label def create_dns_record
    dns_zone.insert_record(record_name: postgres_resource.hostname, type: "A", ttl: 10, data: vm.ephemeral_net4.to_s)
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_mount_data_disk if leaf?
    donate
  end

  label def mount_data_disk
    case vm.sshable.cmd("common/bin/daemonizer --check format_disk")
    when "Succeeded"
      vm.sshable.cmd("sudo mkdir -p /dat")
      device_path = vm.vm_storage_volumes.find { _1.boot == false }.device_path.shellescape

      vm.sshable.cmd("sudo common/bin/add_to_fstab #{device_path} /dat ext4 defaults 0 0")
      vm.sshable.cmd("sudo mount #{device_path} /dat")

      hop_install_postgres
    when "Failed", "NotStarted"
      device_path = vm.vm_storage_volumes.find { _1.boot == false }.device_path.shellescape
      vm.sshable.cmd("common/bin/daemonizer 'sudo mkfs --type ext4 #{device_path}' format_disk")
    end

    nap 5
  end

  label def install_postgres
    case vm.sshable.cmd("common/bin/daemonizer --check install_postgres")
    when "Succeeded"
      hop_initialize_certificates
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/install_postgres' install_postgres")
    end

    nap 5
  end

  label def initialize_certificates
    # Each root will be valid for 10 years and will be used to generate server
    # certificates between its 4th and 9th years. To simulate this behaviour
    # without excessive branching, we create the very first root certificate
    # with only 5 year validity. So it would look like it is created 5 years
    # ago.
    postgres_resource.root_cert_1, postgres_resource.root_cert_key_1 = create_root_certificate(duration: 60 * 60 * 24 * 365 * 5)
    postgres_resource.root_cert_2, postgres_resource.root_cert_key_2 = create_root_certificate(duration: 60 * 60 * 24 * 365 * 10)
    create_server_certificate

    postgres_resource.save_changes
    hop_configure
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
    end

    if OpenSSL::X509::Certificate.new(postgres_resource.server_cert).not_after < Time.now + 60 * 60 * 24 * 30
      create_server_certificate
    end

    postgres_resource.certificate_last_checked_at = Time.now
    postgres_resource.save_changes

    hop_wait
  end

  label def configure
    case vm.sshable.cmd("common/bin/daemonizer --check configure")
    when "Succeeded"
      when_initial_provisioning_set? do
        hop_update_superuser_password
      end
      hop_wait
    when "Failed", "NotStarted"
      configure_hash = postgres_resource.configure_hash
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/configure' configure", stdin: JSON.generate(configure_hash))
    end

    nap 5
  end

  label def update_superuser_password
    encrypted_password = DB.synchronize do |conn|
      # This uses PostgreSQL's PQencryptPasswordConn function, but it needs a connection, because
      # the encryption is made by PostgreSQL, not by control plane. We use our own control plane
      # database to do the encryption.
      conn.encrypt_password(postgres_resource.superuser_password, "postgres", "scram-sha-256")
    end
    commands = <<SQL
BEGIN;
SET LOCAL log_statement = 'none';
ALTER ROLE postgres WITH PASSWORD #{DB.literal(encrypted_password)};
COMMIT;
SQL
    vm.sshable.cmd("sudo -u postgres psql", stdin: commands)

    when_initial_provisioning_set? do
      hop_restart
    end
    hop_wait
  end

  label def restart
    decr_restart
    vm.sshable.cmd("sudo postgres/bin/restart")

    when_initial_provisioning_set? do
      hop_create_billing_record
    end
    hop_wait
  end

  label def create_billing_record
    BillingRecord.create_with_id(
      project_id: postgres_resource.project_id,
      resource_id: postgres_resource.id,
      resource_name: postgres_resource.server_name,
      billing_rate_id: BillingRate.from_resource_properties("PostgresCores", "standard", postgres_resource.location)["id"],
      amount: vm.cores
    )

    BillingRecord.create_with_id(
      project_id: postgres_resource.project_id,
      resource_id: postgres_resource.id,
      resource_name: postgres_resource.server_name,
      billing_rate_id: BillingRate.from_resource_properties("PostgresStorage", "standard", postgres_resource.location)["id"],
      amount: postgres_resource.target_storage_size_gib
    )

    decr_initial_provisioning

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

    if vm
      vm.private_subnets.each { _1.incr_destroy }
      vm.incr_destroy
      nap 5
    end

    dns_zone.delete_record(record_name: postgres_resource.hostname)
    postgres_resource.dissociate_with_project(postgres_resource.project)
    postgres_resource.destroy

    pop "postgres resource is deleted"
  end

  def dns_zone
    @@dns_zone ||= DnsZone.where(project_id: Config.postgres_service_project_id, name: "postgres.ubicloud.com").first
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

    postgres_resource.server_cert, postgres_resource.server_cert_key = Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{postgres_resource.ubid} Server Certificate",
      extensions: ["subjectAltName=DNS:#{postgres_resource.hostname}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
      duration: 60 * 60 * 24 * 30 * 6, # ~6 months
      issuer_cert: root_cert,
      issuer_key: root_cert_key
    ).map(&:to_pem)
    postgres_resource.save_changes

    vm.sshable.cmd("sudo -u postgres tee /dat/16/data/server.crt > /dev/null", stdin: postgres_resource.server_cert)
    vm.sshable.cmd("sudo -u postgres tee /dat/16/data/server.key > /dev/null", stdin: postgres_resource.server_cert_key)
    vm.sshable.cmd("sudo -u postgres chmod 600 /dat/16/data/server.key")
    vm.sshable.cmd("sudo -u postgres pg_ctlcluster 16 main reload")
  end
end
