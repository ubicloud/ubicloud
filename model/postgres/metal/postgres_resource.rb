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
  end
end
