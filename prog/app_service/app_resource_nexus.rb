# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::AppService::AppResourceNexus < Prog::Base
  subject_is :app_resource

  def self.assemble(project_id:, location_id:, name:, repo_url:, branch:, target_vm_size:)
    Validation.validate_name(name)

    DB.transaction do
      app_resource = AppResource.create(
        project_id:,
        location_id:,
        name:,
        repo_url:,
        branch:,
        target_vm_size:,
      )

      # All backing resources live in the Ubicloud-owned app service project.
      firewall = Firewall.create(name: "#{app_resource.ubid}-firewall", location_id:, description: "App Service default firewall", project_id: Config.app_service_project_id)
      private_subnet_id = Prog::Vnet::SubnetNexus.assemble(Config.app_service_project_id, name: "#{app_resource.ubid}-subnet", location_id:, firewall_id: firewall.id).id

      # Allow the control plane to reach the servers over SSH.
      firewall.replace_firewall_rules(
        Config.control_plane_outbound_cidrs.map { {cidr: it, port_range: Sequel.pg_range(22..22)} },
      )

      # Per-app secret store holding config + secrets. App servers read it via
      # their managed identity (granted below in AppServerNexus.assemble).
      secret_store = SecretStore.create(project_id: Config.app_service_project_id, name: app_resource.ubid)

      app_resource.update(private_subnet_id:, secret_store_id: secret_store.id)

      Prog::AppService::AppServerNexus.assemble(app_resource)

      Strand.create_with_id(app_resource, prog: "AppService::AppResourceNexus", label: "wait_servers")
    end
  end

  label def wait_servers
    register_deadline("wait", 10 * 60)

    if Strand.where(id: app_resource.servers_dataset.select(:id)).exclude(label: "wait").empty?
      hop_wait
    end

    nap 10
  end

  label def wait
    when_destroy_set? do
      hop_destroy
    end

    nap 60 * 60 * 24 * 30
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    firewall = app_resource.private_subnet.firewalls_dataset.first(name: "#{app_resource.ubid}-firewall")
    firewall.destroy
    app_resource.private_subnet.incr_destroy

    AppServer.incr_destroy(app_resource.servers_dataset.select(:id))
    hop_wait_servers_destroyed
  end

  label def wait_servers_destroyed
    nap 10 unless app_resource.servers_dataset.empty?

    secret_store = app_resource.secret_store
    app_resource.destroy
    AccessControlEntry.where(object_id: secret_store.id).destroy
    secret_store.destroy

    pop "app resource destroyed"
  end
end
