# frozen_string_literal: true

class Serializers::PostgresMigration < Serializers::Base
  def self.serialize_internal(migration, options = {})
    base = {
      id: migration.ubid,
      status: migration.status,
      display_state: migration.display_state,
      source_host: migration.masked_host,
      created_at: migration.created_at&.iso8601
    }

    if options[:detailed]
      base.merge!({
        discovered_metadata: migration.discovered_metadata,
        selected_region: migration.selected_region,
        selected_vm_size: migration.selected_vm_size,
        selected_storage_size_gib: migration.selected_storage_size_gib,
        selected_pg_version: migration.selected_pg_version,
        discovery_completed_at: migration.discovery_completed_at&.iso8601,
        migration_started_at: migration.migration_started_at&.iso8601,
        completed_at: migration.completed_at&.iso8601,
        databases: migration.migration_databases.map { |db|
          {
            id: db.ubid,
            name: db.name,
            size_bytes: db.size_bytes,
            display_size: db.display_size,
            table_count: db.table_count,
            selected: db.selected,
            migration_status: db.migration_status,
            error_message: db.error_message
          }
        }
      })

      if migration.target_resource
        base[:target] = {
          id: migration.target_resource.ubid,
          name: migration.target_resource.name,
          location: migration.target_resource.display_location,
          connection_string: migration.status == "completed" ? migration.target_resource.connection_string : nil
        }
      end
    end

    base
  end
end
