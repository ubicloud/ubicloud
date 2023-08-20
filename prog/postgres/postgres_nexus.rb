# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Postgres::PostgresNexus < Prog::Base
  subject_is :postgres_server

  extend Forwardable
  def_delegators :postgres_server, :vm

  semaphore :initial_provisioning, :restart, :destroy

  def self.assemble(project_id, location, server_name, vm_size, storage_size_gib)
    unless (project = Project[project_id])
      fail "No existing project"
    end

    Validation.validate_vm_size(vm_size)
    Validation.validate_name(server_name)
    Validation.validate_location(location, project.provider)

    DB.transaction do
      ubid = PostgresServer.generate_ubid

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

      postgres_server = PostgresServer.create(
        project_id: project_id, location: location, server_name: server_name,
        target_vm_size: vm_size, target_storage_size_gib: storage_size_gib,
        superuser_password: SecureRandom.base64(15).gsub(/[+\/]/, "+" => "_", "/" => "-"),
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }
      postgres_server.associate_with_project(project)

      Strand.create(prog: "Postgres::PostgresNexus", label: "start") { _1.id = postgres_server.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        postgres_server.active_billing_records.each(&:finalize)
        hop_destroy
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    vm.sshable.update(host: vm.ephemeral_net4)

    postgres_server.incr_initial_provisioning
    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    register_deadline(:wait, 10 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => vm.id, "user" => "ubi"}
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
      hop_configure
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/install_postgres' install_postgres")
    end

    nap 5
  end

  label def configure
    case vm.sshable.cmd("common/bin/daemonizer --check configure")
    when "Succeeded"
      when_initial_provisioning_set? do
        hop_update_superuser_password
      end
      hop_wait
    when "Failed", "NotStarted"
      configure_hash = postgres_server.configure_hash
      vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/configure' configure", stdin: JSON.generate(configure_hash))
    end

    nap 5
  end

  label def update_superuser_password
    encrypted_password = DB.synchronize do |conn|
      # This uses PostgreSQL's PQencryptPasswordConn function, but it needs a connection, because
      # the encryption is made by PostgreSQL, not by control plane. We use our own control plane
      # database to do the encryption.
      conn.encrypt_password(postgres_server.superuser_password, "postgres", "scram-sha-256")
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
      project_id: postgres_server.project_id,
      resource_id: postgres_server.id,
      resource_name: postgres_server.server_name,
      billing_rate_id: BillingRate.from_resource_properties("PostgresCores", "standard", postgres_server.location)["id"],
      amount: vm.cores
    )

    BillingRecord.create_with_id(
      project_id: postgres_server.project_id,
      resource_id: postgres_server.id,
      resource_name: postgres_server.server_name,
      billing_rate_id: BillingRate.from_resource_properties("PostgresStorage", "standard", postgres_server.location)["id"],
      amount: postgres_server.target_storage_size_gib
    )

    decr_initial_provisioning

    hop_wait
  end

  label def wait
    nap 30
  end

  label def destroy
    register_deadline(nil, 5 * 60)

    decr_destroy

    if vm
      vm.private_subnets.each { _1.incr_destroy }
      vm.sshable&.destroy
      vm.incr_destroy
      nap 5
    end

    postgres_server.dissociate_with_project(postgres_server.project)
    postgres_server.destroy

    pop "postgres server is deleted"
  end
end
