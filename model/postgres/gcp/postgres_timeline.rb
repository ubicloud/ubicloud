# frozen_string_literal: true

class PostgresTimeline < Sequel::Model
  module Gcp
    private

    def gcp_walg_config_region
      raise "GCP Postgres not yet supported"
    end

    def gcp_blob_storage
      raise "GCP Postgres not yet supported"
    end

    def gcp_blob_storage_client
      raise "GCP Postgres not yet supported"
    end

    def gcp_list_objects(prefix, delimiter: "")
      raise "GCP Postgres not yet supported"
    end

    def gcp_create_bucket
      raise "GCP Postgres not yet supported"
    end

    def gcp_set_lifecycle_policy
      raise "GCP Postgres not yet supported"
    end
  end
end

# Table: postgres_timeline
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  created_at                | timestamp with time zone | NOT NULL DEFAULT now()
#  parent_id                 | uuid                     |
#  access_key                | text                     |
#  secret_key                | text                     |
#  latest_backup_started_at  | timestamp with time zone |
#  location_id               | uuid                     |
#  cached_earliest_backup_at | timestamp with time zone |
#  backup_period_hours       | smallint                 | NOT NULL DEFAULT 24
# Indexes:
#  postgres_timeline_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_timeline_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_server | postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
