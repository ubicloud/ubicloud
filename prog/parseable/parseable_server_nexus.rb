# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Parseable::ParseableServerNexus < Prog::Base
  subject_is :parseable_server

  extend Forwardable

  def_delegators :parseable_server, :vm, :resource

  def self.assemble(parseable_resource)
    DB.transaction do
      ubid = ParseableServer.generate_ubid
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.parseable_service_project_id,
        sshable_unix_user: "ubi",
        location_id: parseable_resource.location.id,
        name: ubid.to_s,
        size: parseable_resource.target_vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30},
          {encrypted: true, size_gib: parseable_resource.target_storage_size_gib},
        ],
        boot_image: "ubuntu-noble",
        private_subnet_id: parseable_resource.private_subnet_id,
        enable_ip4: true,
      )

      id = ubid.to_uuid
      ParseableServer.create_with_id(id, parseable_resource_id: parseable_resource.id, vm_id: vm_st.id)
      Strand.create_with_id(id, prog: "Parseable::ParseableServerNexus", label: "start")
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    incr_initial_provisioning

    register_deadline("wait", 10 * 60)

    resource.dns_zone&.insert_record(record_name: resource.hostname, type: "A", ttl: 10, data: vm.ip4_string)
    resource.dns_zone&.insert_record(record_name: resource.hostname, type: "AAAA", ttl: 10, data: vm.ip6_string)
    cert, cert_key = create_certificate
    parseable_server.update(cert:, cert_key:)

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "parseable", "subject_id" => vm.id, "user" => "ubi"}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap(:create_parseable_user)
  end

  label def create_parseable_user
    begin
      vm.sshable.cmd("sudo groupadd -f --system parseable")
      vm.sshable.cmd("sudo useradd --no-create-home --system -g parseable parseable")
    rescue => ex
      raise unless ex.message.include?("already exists")
    end

    hop_install
  end

  label def install
    case vm.sshable.d_check("install_parseable")
    when "Succeeded"
      vm.sshable.d_clean("install_parseable")
      hop_mount_data_disk
    when "Failed", "NotStarted"
      vm.sshable.d_run("install_parseable", "/home/ubi/parseable/bin/install", Config.parseable_version)
    end
    nap 5
  end

  label def mount_data_disk
    case vm.sshable.d_check("format_parseable_disk")
    when "Succeeded"
      vm.sshable.cmd("sudo mkdir -p /dat/parseable")
      volume = vm.vm_storage_volumes_dataset.order_by(:disk_index).where(Sequel[:vm_storage_volume][:boot] => false).first
      device_path = volume.device_path
      vm.sshable.cmd("sudo common/bin/add_to_fstab :device_path /dat/parseable ext4 defaults 0 0", device_path:)
      vm.sshable.cmd("sudo mount :device_path /dat/parseable", device_path:)
      vm.sshable.cmd("sudo chown -R parseable:parseable /dat/parseable")

      hop_configure
    when "Failed", "NotStarted"
      volume = vm.vm_storage_volumes_dataset.order_by(:disk_index).where(Sequel[:vm_storage_volume][:boot] => false).first
      device_path = volume.device_path
      vm.sshable.d_run("format_parseable_disk", "mkfs.ext4", device_path)
    end
    nap 5
  end

  label def configure
    case vm.sshable.d_check("configure_parseable")
    when "Succeeded"
      vm.sshable.d_clean("configure_parseable")
      hop_wait
    when "Failed", "NotStarted"
      config_json = JSON.generate({
        admin_user: resource.admin_user,
        admin_password: resource.admin_password,
        cert: parseable_server.cert,
        cert_key: parseable_server.cert_key,
        ca_bundle: resource.root_certs,
        s3_url: resource.blob_storage_endpoint,
        s3_bucket: resource.bucket_name,
        s3_access_key: resource.access_key,
        s3_secret_key: resource.secret_key,
        s3_ca_bundle: resource.blob_storage.root_certs,
      })

      vm.sshable.d_run("configure_parseable", "/home/ubi/parseable/bin/configure", stdin: config_json)
    end
    nap 5
  end

  label def wait
    when_checkup_set? do
      hop_unavailable if !available?
      decr_checkup
    end

    when_reconfigure_set? do
      decr_reconfigure
      hop_configure
    end

    when_restart_set? do
      decr_restart
      clear_restart_state
      hop_wait if daemonized_restart
    end

    if parseable_server.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    nap 60 * 60 * 24 * 30
  end

  label def refresh_certificates
    cert, cert_key = create_certificate
    parseable_server.update(cert:, cert_key:, certificate_last_checked_at: Time.now)

    incr_reconfigure
    hop_wait
  end

  label def unavailable
    register_deadline("wait", 10 * 60)

    if available?
      decr_checkup
      clear_restart_state
      hop_wait
    end

    daemonized_restart
    nap 5
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    resource.dns_zone&.delete_record(record_name: resource.hostname, type: "A", data: vm.ip4_string)
    resource.dns_zone&.delete_record(record_name: resource.hostname, type: "AAAA", data: vm.ip6_string)
    Semaphore.incr(strand.children_dataset.select(:id), "destroy")
    hop_wait_children_destroyed
  end

  label def wait_children_destroyed
    reap(nap: 5) do
      vm.incr_destroy
      parseable_server.destroy

      pop "parseable server destroyed"
    end
  end

  def available?
    return true if parseable_server.initial_provisioning_set?

    parseable_server.client.healthy?
  rescue => ex
    Clog.emit("parseable server is down", {parseable_server_down: Util.exception_to_hash(ex, into: {ubid: parseable_server.ubid})})
    false
  end

  def daemonized_restart
    case vm.sshable.d_check("restart_parseable")
    when "Succeeded"
      vm.sshable.d_clean("restart_parseable")
      return true
    when "Failed", "NotStarted"
      vm.sshable.d_run("restart_parseable", "/home/ubi/parseable/bin/restart")
    end
    false
  end

  def clear_restart_state
    vm.sshable.d_clean("restart_parseable") if vm.sshable.d_check("restart_parseable") == "Succeeded"
  end

  def create_certificate
    root_cert = OpenSSL::X509::Certificate.new(resource.root_cert_1)
    root_cert_key = OpenSSL::PKey::EC.new(resource.root_cert_key_1)
    if root_cert.not_after < Time.now + 60 * 60 * 24 * 365 * 1
      root_cert = OpenSSL::X509::Certificate.new(resource.root_cert_2)
      root_cert_key = OpenSSL::PKey::EC.new(resource.root_cert_key_2)
    end

    ip_san = (Config.development? || Config.is_e2e) ? ",IP:#{vm.ip4},IP:#{vm.ip6}" : nil

    Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{resource.ubid} Server Certificate",
      extensions: ["subjectAltName=DNS:#{resource.hostname},DNS:#{resource.hostname}#{ip_san}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
      duration: 60 * 60 * 24 * 30 * 6, # ~6 months
      issuer_cert: root_cert,
      issuer_key: root_cert_key,
    ).map(&:to_pem)
  end
end
