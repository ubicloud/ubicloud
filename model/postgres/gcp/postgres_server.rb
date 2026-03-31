# frozen_string_literal: true

class PostgresServer < Sequel::Model
  module Gcp
    private

    def gcp_add_provider_configs(configs)
      raise "GCP Postgres not yet supported"
    end

    def gcp_refresh_walg_blob_storage_credentials
      raise "GCP Postgres not yet supported"
    end

    def gcp_storage_device_paths
      raise "GCP Postgres not yet supported"
    end

    def gcp_attach_s3_policy_if_needed
      raise "GCP Postgres not yet supported"
    end

    def gcp_increment_s3_new_timeline
      raise "GCP Postgres not yet supported"
    end
  end
end

# Table: postgres_server
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  created_at             | timestamp with time zone | NOT NULL DEFAULT now()
#  resource_id            | uuid                     | NOT NULL
#  vm_id                  | uuid                     |
#  timeline_id            | uuid                     | NOT NULL
#  timeline_access        | timeline_access          | NOT NULL DEFAULT 'push'::timeline_access
#  synchronization_status | synchronization_status   | NOT NULL DEFAULT 'ready'::synchronization_status
#  version                | text                     | NOT NULL
#  is_representative      | boolean                  | NOT NULL DEFAULT false
#  physical_slot_ready_id | uuid                     |
# Indexes:
#  postgres_server_pkey1                             | PRIMARY KEY btree (id)
#  postgres_server_resource_id_is_representative_idx | UNIQUE btree (resource_id) WHERE is_representative IS TRUE
#  postgres_server_resource_id_index                 | btree (resource_id)
# Check constraints:
#  version_check | (version = ANY (ARRAY['16'::text, '17'::text, '18'::text]))
# Foreign key constraints:
#  postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
#  postgres_server_vm_id_fkey       | (vm_id) REFERENCES vm(id)
