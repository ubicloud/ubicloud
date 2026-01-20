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

    def metal_new_server_exclusion_filters
      # If the server is in leaseweb, we don't have multiple DCs, that's
      # why we return an empty list of data centers.
      return ServerExclusionFilters.new(exclude_host_ids: [], exclude_data_centers: [], exclude_availability_zones: [], availability_zone: nil) if Config.allow_unspread_servers
      return ServerExclusionFilters.new(exclude_host_ids: [representative_server.vm.vm_host_id], exclude_data_centers: [], exclude_availability_zones: [], availability_zone: nil) if location.provider == HostProvider::LEASEWEB_PROVIDER_NAME

      exclude_data_centers = VmHost
        .where(data_center: VmHost
          .join(:vm, vm_host_id: :id)
          .where(Sequel[:vm][:id] => servers_dataset.select(:vm_id))
          .select(:data_center)
          .distinct)
        .select_map(:data_center)

      ServerExclusionFilters.new(exclude_host_ids: [], exclude_data_centers:, exclude_availability_zones: [], availability_zone: nil)
    end
  end
end
