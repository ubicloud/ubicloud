# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::VictoriaMetrics::VictoriaMetricsResourceNexus < Prog::Base
  subject_is :victoria_metrics_resource

  def self.assemble(project_id, name, location_id, admin_user, admin_password, storage_size_gb, node_count, vm_size)
    project = Project[project_id]
    fail "No existing project" unless project

    location = Location[location_id]
    fail "No existing location" unless location

    unless node_count == 1
      fail "Only single node is supported"
    end

    Validation.validate_vm_size(vm_size, "x64")
    Validation.validate_name(name)
    Validation.validate_minio_username(admin_user)

    DB.transaction do
      ubid = VictoriaMetricsResource.generate_ubid
      root_cert_1, root_cert_key_1 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
      root_cert_2, root_cert_key_2 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)

      victoria_metrics_resource = VictoriaMetricsResource.create(
        name: name,
        location_id: location.id,
        admin_user: admin_user,
        admin_password: admin_password,
        root_cert_1: root_cert_1,
        root_cert_key_1: root_cert_key_1,
        root_cert_2: root_cert_2,
        root_cert_key_2: root_cert_key_2,
        target_vm_size: vm_size,
        project_id: project.id
      )

      node_count.times do |i|
        # Pad node name with 0s to ensure consistent ordering
        node_name = "#{name}-node-#{(i + 1).to_s.rjust(2, "0")}"

        Prog::VictoriaMetrics::VictoriaMetricsServerNexus.assemble(
          victoria_metrics_resource.id,
          node_name
        )
      end

      Strand.create(prog: "VictoriaMetrics::VictoriaMetricsResourceNexus", label: "wait_servers") { _1.id = victoria_metrics_resource.id }
    end
  end

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_servers_destroyed"].include?(strand.label)
        hop_destroy
      end
    end
  end

  label def wait_servers
    register_deadline("wait", 10 * 60)

    if victoria_metrics_resource.servers.all? { _1.strand.label == "wait" }
      hop_wait
    end

    nap 10
  end

  label def wait
    if victoria_metrics_resource.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    when_reconfigure_set? do
      hop_reconfigure
    end

    nap 30
  end

  label def refresh_certificates
    if OpenSSL::X509::Certificate.new(victoria_metrics_resource.root_cert_1).not_after < Time.now + 60 * 60 * 24 * 30 * 5
      victoria_metrics_resource.root_cert_1, victoria_metrics_resource.root_cert_key_1 = victoria_metrics_resource.root_cert_2, victoria_metrics_resource.root_cert_key_2
      victoria_metrics_resource.root_cert_2, victoria_metrics_resource.root_cert_key_2 = Util.create_root_certificate(common_name: "#{victoria_metrics_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
      victoria_metrics_resource.servers.map(&:incr_reconfigure)
    end

    victoria_metrics_resource.certificate_last_checked_at = Time.now
    victoria_metrics_resource.save_changes

    hop_wait
  end

  label def reconfigure
    decr_reconfigure
    victoria_metrics_resource.servers.map(&:incr_reconfigure)
    victoria_metrics_resource.servers.map(&:incr_restart)
    hop_wait
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy
    victoria_metrics_resource.servers.each(&:incr_destroy)
    hop_wait_servers_destroyed
  end

  label def wait_servers_destroyed
    nap 10 unless victoria_metrics_resource.servers.empty?
    victoria_metrics_resource.destroy

    pop "destroyed"
  end
end
