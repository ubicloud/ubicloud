# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::VictoriaMetrics::VictoriaMetricsServerNexus < Prog::Base
  subject_is :victoria_metrics_server

  extend Forwardable
  def_delegators :victoria_metrics_server, :vm

  def self.assemble(victoria_metrics_resource_id, name)
    vr = VictoriaMetricsResource[victoria_metrics_resource_id]
    fail "No existing VictoriaMetricsResource" unless vr
    Validation.validate_name(name)

    DB.transaction do
      ubid = VictoriaMetricsServer.generate_ubid
      vm_st = Prog::Vm::Nexus.assemble_with_sshable(
        Config.victoriametrics_service_project_id,
        sshable_unix_user: "ubi",
        location_id: vr.location.id,
        name: ubid.to_s,
        size: vr.target_vm_size,
        boot_image: "ubuntu-noble",
        enable_ip4: true
      )

      vs = VictoriaMetricsServer.create(name: name, victoria_metrics_resource_id: victoria_metrics_resource_id, vm_id: vm_st.id) { _1.id = ubid.to_uuid }
      Strand.create(prog: "VictoriaMetrics::VictoriaMetricsServerNexus", label: "start") { _1.id = vs.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the victoriametrics server"
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
    bud Prog::BootstrapRhizome, {"target_folder" => "victoriametrics", "subject_id" => vm.id, "user" => "ubi"}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_create_victoriametrics_user if leaf?
    donate
  end

  label def create_victoriametrics_user
    begin
      victoria_metrics_server.vm.sshable.cmd("sudo groupadd -f --system victoriametrics")
      victoria_metrics_server.vm.sshable.cmd("sudo useradd --no-create-home --system -g victoriametrics victoriametrics")
    rescue => ex
      raise unless ex.message.include?("already exists")
    end

    hop_setup
  end

  label def setup
    bud Prog::VictoriaMetrics::VictoriaMetricsSetup, {}, :install
    bud Prog::VictoriaMetrics::VictoriaMetricsSetup, {}, :configure

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
    when_reconfigure_set? do
      bud Prog::VictoriaMetrics::VictoriaMetricsSetup, {}, :configure
      decr_reconfigure
    end

    when_restart_set? do
      decr_restart

      push self.class, frame, "restart"
    end

    if victoria_metrics_server.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    nap 10
  end

  label def refresh_certificates
    cert, cert_key = create_certificate
    victoria_metrics_server.update(cert: cert, cert_key: cert_key, certificate_last_checked_at: Time.now)

    incr_reconfigure
    hop_wait
  end

  label def wait_reconfigure
    decr_reconfigure

    victoria_metrics_server.vm.sshable.cmd("systemctl reload vmauth")

    reap
    if leaf?
      hop_wait
    end
    donate
  end

  label def restart
    case victoria_metrics_server.vm.sshable.cmd("common/bin/daemonizer --check restart_victoriametrics")
    when "Succeeded"
      victoria_metrics_server.vm.sshable.cmd("common/bin/daemonizer --clean restart_victoriametrics")
      pop "victoriametrics server is restarted"
    when "Failed", "NotStarted"
      victoria_metrics_server.vm.sshable.cmd("common/bin/daemonizer 'systemctl restart victoriametrics && systemctl restart vmauth' restart_victoriametrics")
    end
    nap 1
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    strand.children.each { _1.destroy }
    victoria_metrics_server.vm.incr_destroy
    victoria_metrics_server.destroy

    pop "victoriametrics server destroyed"
  end

  def resource
    @resource ||= victoria_metrics_server.victoriametrics_resource
  end

  def create_certificate
    root_cert = OpenSSL::X509::Certificate.new(victoria_metrics_server.resource.root_cert_1)
    root_cert_key = OpenSSL::PKey::EC.new(victoria_metrics_server.resource.root_cert_key_1)
    if root_cert.not_after < Time.now + 60 * 60 * 24 * 365 * 1
      root_cert = OpenSSL::X509::Certificate.new(victoria_metrics_server.resource.root_cert_2)
      root_cert_key = OpenSSL::PKey::EC.new(victoria_metrics_server.resource.root_cert_key_2)
    end

    ip_san = (Config.development? || Config.is_e2e) ? ",IP:#{victoria_metrics_server.vm.ephemeral_net4},IP:#{victoria_metrics_server.vm.ephemeral_net6.nth(2)}" : nil

    Util.create_certificate(
      subject: "/C=US/O=Ubicloud/CN=#{victoria_metrics_server.resource.ubid} Server Certificate",
      extensions: ["subjectAltName=DNS:#{victoria_metrics_server.resource.hostname},DNS:#{victoria_metrics_server.resource.hostname}#{ip_san}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
      duration: 60 * 60 * 24 * 30 * 6, # ~6 months
      issuer_cert: root_cert,
      issuer_key: root_cert_key
    ).map(&:to_pem)
  end
end
