# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::VictoriaMetrics::VictoriaMetricsServerNexus < Prog::Base
  subject_is :victoria_metrics_server

  extend Forwardable
  def_delegators :victoria_metrics_server, :vm, :resource

  def self.assemble(victoria_metrics_resource_id)
    vr = VictoriaMetricsResource[victoria_metrics_resource_id]
    fail "No existing VictoriaMetricsResource" unless vr

    DB.transaction do
      ubid = VictoriaMetricsServer.generate_ubid
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.victoria_metrics_service_project_id,
        sshable_unix_user: "ubi",
        location_id: vr.location.id,
        name: ubid.to_s,
        size: vr.target_vm_size,
        storage_volumes: [
          {encrypted: true, size_gib: 30},
          {encrypted: true, size_gib: vr.target_storage_size_gib}
        ],
        boot_image: "ubuntu-noble",
        private_subnet_id: vr.private_subnet_id,
        enable_ip4: true
      )

      vs = VictoriaMetricsServer.create(victoria_metrics_resource_id:, vm_id: vm_st.id) { it.id = ubid.to_uuid }
      Strand.create(prog: "VictoriaMetrics::VictoriaMetricsServerNexus", label: "start") { it.id = vs.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the VictoriaMetrics server"
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"
    victoria_metrics_server.incr_initial_provisioning

    register_deadline("wait", 10 * 60)

    cert, cert_key = create_certificate
    victoria_metrics_server.update(cert: cert, cert_key: cert_key)

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "victoria_metrics", "subject_id" => vm.id, "user" => "ubi"}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_create_victoria_metrics_user if leaf?
    donate
  end

  label def create_victoria_metrics_user
    begin
      vm.sshable.cmd("sudo groupadd -f --system victoria_metrics")
      vm.sshable.cmd("sudo useradd --no-create-home --system -g victoria_metrics victoria_metrics")
    rescue => ex
      raise unless ex.message.include?("already exists")
    end

    hop_install
  end

  label def install
    case vm.sshable.d_check("install_victoria_metrics")
    when "Succeeded"
      vm.sshable.d_clean("install_victoria_metrics")
      hop_configure
    when "Failed", "NotStarted"
      vm.sshable.d_run("install_victoria_metrics", "/home/ubi/victoria_metrics/bin/install", Config.victoria_metrics_version)
    end
    nap 5
  end

  label def mount_data_disk
    case vm.sshable.d_check("format_victoria_metrics_disk")
    when "Succeeded"
      vm.sshable.cmd("sudo mkdir -p /dat/victoria_metrics")
      volume = vm.vm_storage_volumes_dataset.order_by(:disk_index).where(Sequel[:vm_storage_volume][:boot] => false).first
      device_path = volume.device_path.shellescape
      vm.sshable.cmd("sudo common/bin/add_to_fstab #{device_path} /dat/victoria_metrics ext4 defaults 0 0")
      vm.sshable.cmd("sudo mount #{device_path} /dat/victoria_metrics")
      vm.sshable.cmd("sudo chown -R victoria_metrics:victoria_metrics /dat/victoria_metrics")

      hop_configure
    when "Failed", "NotStarted"
      volume = vm.vm_storage_volumes_dataset.order_by(:disk_index).where(Sequel[:vm_storage_volume][:boot] => false).first
      device_path = volume.device_path.shellescape
      cmd = ["mkfs.ext4", device_path]
      vm.sshable.d_run("format_victoria_metrics_disk", *cmd)
    end
    nap 5
  end

  label def configure
    case vm.sshable.d_check("configure_victoria_metrics")
    when "Succeeded"
      vm.sshable.d_clean("configure_victoria_metrics")
      hop_wait
    when "Failed", "NotStarted"
      config_json = JSON.generate({
        admin_user: resource.admin_user,
        admin_password: resource.admin_password,
        cert: victoria_metrics_server.cert,
        cert_key: victoria_metrics_server.cert_key,
        ca_bundle: resource.root_certs
      })

      vm.sshable.d_run("configure_victoria_metrics", "/home/ubi/victoria_metrics/bin/configure", stdin: config_json)
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
      push self.class, frame, "restart"
    end

    if victoria_metrics_server.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    nap 60 * 60 * 24 * 30
  end

  label def refresh_certificates
    cert, cert_key = create_certificate
    victoria_metrics_server.update(cert:, cert_key:, certificate_last_checked_at: Time.now)

    incr_reconfigure
    hop_wait
  end

  label def restart
    decr_restart
    case vm.sshable.d_check("restart_victoria_metrics")
    when "Succeeded"
      vm.sshable.d_clean("restart_victoria_metrics")
      pop "victoria_metrics server is restarted"
    when "Failed", "NotStarted"
      vm.sshable.d_run("restart_victoria_metrics", "/home/ubi/victoria_metrics/bin/restart")
    end
    nap 1
  end

  label def unavailable
    register_deadline("wait", 10 * 60)

    reap
    nap 5 unless strand.children.select { it.prog == "VictoriaMetrics::VictoriaMetricsServerNexus" && it.label == "restart" }.empty?

    if available?
      decr_checkup
      hop_wait
    end

    bud self.class, frame, :restart
    nap 5
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    strand.children.each(&:destroy)
    vm.incr_destroy
    victoria_metrics_server.destroy

    pop "victoria_metrics server destroyed"
  end

  def available?
    return true if victoria_metrics_server.initial_provisioning_set?

    victoria_metrics_server.client.health
  rescue => ex
    Clog.emit("victoria_metrics server is down") { {victoria_metrics_server_down: {ubid: victoria_metrics_server.ubid, exception: Util.exception_to_hash(ex)}} }
    false
  end

  def create_certificate
    root_cert = OpenSSL::X509::Certificate.new(resource.root_cert_1)
    root_cert_key = OpenSSL::PKey::EC.new(resource.root_cert_key_1)
    if root_cert.not_after < Time.now + 60 * 60 * 24 * 365 * 1
      root_cert = OpenSSL::X509::Certificate.new(resource.root_cert_2)
      root_cert_key = OpenSSL::PKey::EC.new(resource.root_cert_key_2)
    end

    ip_san = (Config.development? || Config.is_e2e) ? ",IP:#{vm.ephemeral_net4},IP:#{vm.ephemeral_net6.nth(2)}" : nil

    Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{resource.ubid} Server Certificate",
      extensions: ["subjectAltName=DNS:#{resource.hostname},DNS:#{resource.hostname}#{ip_san}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
      duration: 60 * 60 * 24 * 30 * 6, # ~6 months
      issuer_cert: root_cert,
      issuer_key: root_cert_key
    ).map(&:to_pem)
  end
end
