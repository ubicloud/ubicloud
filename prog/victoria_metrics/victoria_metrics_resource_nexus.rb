# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::VictoriaMetrics::VictoriaMetricsResourceNexus < Prog::Base
  subject_is :victoria_metrics_resource

  def self.assemble(project_id, name, location_id, admin_user, vm_size, storage_size_gib)
    project = Project[project_id]
    fail "No existing project" unless project

    location = Location[location_id]
    fail "No existing location" unless location

    Validation.validate_name(name)
    Validation.validate_victoria_metrics_username(admin_user)
    Validation.validate_vm_size(vm_size, "x64")
    storage_size_gib = Validation.validate_victoria_metrics_storage_size(storage_size_gib)

    DB.transaction do
      ubid = VictoriaMetricsResource.generate_ubid
      root_cert_1, root_cert_key_1 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
      root_cert_2, root_cert_key_2 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)

      victoria_metrics_resource = VictoriaMetricsResource.create(
        name:,
        location_id: location.id,
        admin_user:,
        admin_password: SecureRandom.urlsafe_base64(15),
        root_cert_1:,
        root_cert_key_1:,
        root_cert_2:,
        root_cert_key_2:,
        target_vm_size: vm_size,
        target_storage_size_gib: storage_size_gib,
        project_id: project.id
      )

      firewall = Firewall.create(name: "#{victoria_metrics_resource.ubid}-firewall", location_id: location.id, description: "VictoriaMetrics default firewall", project_id: Config.victoria_metrics_service_project_id)

      private_subnet_id = Prog::Vnet::SubnetNexus.assemble(Config.victoria_metrics_service_project_id, name: "#{victoria_metrics_resource.ubid}-subnet", location_id: location.id, firewall_id: firewall.id).id
      victoria_metrics_resource.update(private_subnet_id: private_subnet_id)
      victoria_metrics_resource.set_firewall_rules

      Prog::VictoriaMetrics::VictoriaMetricsServerNexus.assemble(victoria_metrics_resource.id)

      Strand.create_with_id(victoria_metrics_resource.id, prog: "VictoriaMetrics::VictoriaMetricsResourceNexus", label: "wait_servers")
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

    if victoria_metrics_resource.servers.all? { it.strand.label == "wait" }
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

    # Nap for 1 month, to check for certs.
    nap 60 * 60 * 24 * 30
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

    victoria_metrics_resource.private_subnet.firewalls.each(&:destroy)
    victoria_metrics_resource.private_subnet.incr_destroy

    victoria_metrics_resource.servers.each(&:incr_destroy)
    hop_wait_servers_destroyed
  end

  label def wait_servers_destroyed
    nap 10 unless victoria_metrics_resource.servers.empty?
    victoria_metrics_resource.destroy

    pop "destroyed"
  end
end
