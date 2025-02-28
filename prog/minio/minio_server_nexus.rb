# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Minio::MinioServerNexus < Prog::Base
  subject_is :minio_server

  extend Forwardable
  def_delegators :minio_server, :vm

  def self.assemble(minio_pool_id, index)
    unless (minio_pool = MinioPool[minio_pool_id])
      fail "No existing pool"
    end

    DB.transaction do
      ubid = MinioServer.generate_ubid

      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        "ubi",
        Config.minio_service_project_id,
        location_id: minio_pool.cluster.location_id,
        name: ubid.to_s,
        size: minio_pool.vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30}
        ] + Array.new(minio_pool.per_server_drive_count) { {encrypted: true, size_gib: (minio_pool.per_server_storage_size / minio_pool.per_server_drive_count).floor} },
        boot_image: "ubuntu-jammy",
        enable_ip4: true,
        private_subnet_id: minio_pool.cluster.private_subnet.id,
        distinct_storage_devices: Config.production? && !Config.is_e2e
      )

      minio_server = MinioServer.create(minio_pool_id: minio_pool_id, vm_id: vm_st.id, index: index) { _1.id = ubid.to_uuid }

      Strand.create(prog: "Minio::MinioServerNexus", label: "start") { _1.id = minio_server.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the minio server"
      end
    end
  end

  def cluster
    @cluster ||= minio_server.cluster
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    minio_server.incr_initial_provisioning

    register_deadline("wait", 10 * 60)

    minio_server.cluster.dns_zone&.insert_record(record_name: cluster.hostname, type: "A", ttl: 10, data: vm.ephemeral_net4.to_s)
    minio_server.cluster.dns_zone&.insert_record(record_name: cluster.hostname, type: "AAAA", ttl: 10, data: vm.ephemeral_net6.nth(2).to_s)
    cert, cert_key = create_certificate
    minio_server.update(cert: cert, cert_key: cert_key)

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "minio", "subject_id" => vm.id, "user" => "ubi"}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_create_minio_user if leaf?
    donate
  end

  label def create_minio_user
    begin
      minio_server.vm.sshable.cmd("sudo groupadd -f --system minio-user")
      minio_server.vm.sshable.cmd("sudo useradd --no-create-home --system -g minio-user minio-user")
    rescue => ex
      raise unless ex.message.include?("already exists")
    end

    hop_setup
  end

  label def setup
    bud Prog::Minio::SetupMinio, {}, :mount_data_disks
    bud Prog::Minio::SetupMinio, {}, :install_minio
    bud Prog::Minio::SetupMinio, {}, :configure_minio
    hop_wait_setup
  end

  label def wait_setup
    reap
    if leaf?
      hop_wait
    end
    donate
  end

  label def wait
    when_checkup_set? do
      hop_unavailable if !available?
      decr_checkup
    end

    when_reconfigure_set? do
      bud Prog::Minio::SetupMinio, {}, :configure_minio
      hop_wait_reconfigure
    end

    when_restart_set? do
      decr_restart

      # We start the minio server only after the initial provisioning is done
      # for all of the servers in the pool.
      when_initial_provisioning_set? do
        decr_initial_provisioning
      end

      push self.class, frame, "minio_restart"
    end

    if minio_server.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    nap 10
  end

  label def refresh_certificates
    cert, cert_key = create_certificate
    minio_server.update(cert: cert, cert_key: cert_key, certificate_last_checked_at: Time.now)

    incr_reconfigure
    hop_wait
  end

  label def wait_reconfigure
    decr_reconfigure
    reap
    if leaf?
      hop_wait
    end
    donate
  end

  label def minio_restart
    case minio_server.vm.sshable.cmd("common/bin/daemonizer --check restart_minio")
    when "Succeeded"
      minio_server.vm.sshable.cmd("common/bin/daemonizer --clean restart_minio")
      pop "minio server is restarted"
    when "Failed", "NotStarted"
      minio_server.vm.sshable.cmd("common/bin/daemonizer 'systemctl restart minio' restart_minio")
    end
    nap 1
  end

  label def unavailable
    register_deadline("wait", 10 * 60)

    reap
    nap 5 unless strand.children.select { _1.prog == "Minio::MinioServerNexus" && _1.label == "minio_restart" }.empty?

    if available?
      decr_checkup
      hop_wait
    end

    bud self.class, frame, :minio_restart
    nap 5
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy
    minio_server.cluster.dns_zone&.delete_record(record_name: cluster.hostname, type: "A", data: vm.ephemeral_net4&.to_s)
    minio_server.cluster.dns_zone&.delete_record(record_name: cluster.hostname, type: "AAAA", data: vm.ephemeral_net6&.nth(2)&.to_s)
    minio_server.vm.sshable.destroy
    minio_server.vm.nics.each { _1.incr_destroy }
    minio_server.vm.incr_destroy
    minio_server.destroy

    pop "minio server destroyed"
  end

  def available?
    return true if minio_server.initial_provisioning_set?
    server_data = JSON.parse(minio_server.client.admin_info.body)["servers"].find { _1["endpoint"] == minio_server.endpoint }
    server_data["state"] == "online" && server_data["drives"].all? { _1["state"] == "ok" }
  rescue => ex
    Clog.emit("Minio server is down") { {minio_server_down: {ubid: minio_server.ubid, exception: Util.exception_to_hash(ex)}} }
    false
  end

  def create_certificate
    root_cert = OpenSSL::X509::Certificate.new(minio_server.cluster.root_cert_1)
    root_cert_key = OpenSSL::PKey::EC.new(minio_server.cluster.root_cert_key_1)
    if root_cert.not_after < Time.now + 60 * 60 * 24 * 365 * 1
      root_cert = OpenSSL::X509::Certificate.new(minio_server.cluster.root_cert_2)
      root_cert_key = OpenSSL::PKey::EC.new(minio_server.cluster.root_cert_key_2)
    end

    ip_san = (Config.development? || Config.is_e2e) ? ",IP:#{minio_server.vm.ephemeral_net4},IP:#{minio_server.vm.ephemeral_net6.nth(2)}" : nil

    Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{minio_server.cluster.ubid} Server Certificate",
      extensions: ["subjectAltName=DNS:#{minio_server.cluster.hostname},DNS:#{minio_server.hostname}#{ip_san}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
      duration: 60 * 60 * 24 * 30 * 6, # ~6 months
      issuer_cert: root_cert,
      issuer_key: root_cert_key
    ).map(&:to_pem)
  end
end
