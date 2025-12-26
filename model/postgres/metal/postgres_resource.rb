# frozen_string_literal: true

class PostgresResource < Sequel::Model
  module Metal
    private

    def metal_upgrade_candidate_server
      servers
        .reject(&:representative_at)
        .select { |server| server.vm.vm_storage_volumes.filter { it.boot }.any? { it.boot_image.version >= UPGRADE_IMAGE_MIN_VERSIONS[target_version] } }
        .max_by(&:created_at)
    end

    # If the server is in leaseweb, we don't have multiple DCs anyway.
    # The first element is the list of vm_hosts to exclude from the new server,
    # which means the dc of the existing servers for metal
    # The second element is the list of availability zones to exclude from the new server,
    # which is empty for metal.
    # The third element is the availability zone of the representative server,
    # which is nil for metal.
    def metal_new_server_exclusion_filters
      return [[], [], nil] if Config.allow_unspread_servers || location.provider == HostProvider::LEASEWEB_PROVIDER_NAME
      [VmHost.where(data_center: servers.map { it.vm.vm_host.data_center }.uniq).map(&:id), [], nil]
    end
  end
end
