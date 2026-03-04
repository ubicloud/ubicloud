# frozen_string_literal: true

class PostgresResource < Sequel::Model
  module Gcp
    private

    def gcp_upgrade_candidate_server
      # GCP VMs don't track boot_image on storage volumes. GCE Postgres
      # images always include all supported PG versions (16/17/18), so
      # any non-representative server is a valid upgrade candidate.
      servers
        .reject(&:is_representative)
        .max_by(&:created_at)
    end

    def gcp_new_server_exclusion_filters
      exclude_availability_zones = Strand
        .join(:nic, Sequel[:strand][:id] => Sequel[:nic][:id])
        .where(Sequel[:nic][:vm_id] => servers_dataset.select(:vm_id))
        .select_map(Sequel.lit("stack->0->>'gcp_zone_suffix'"))
        .compact
        .uniq

      ServerExclusionFilters.new(exclude_host_ids: [], exclude_data_centers: [], exclude_availability_zones:, availability_zone: nil)
    end
  end
end

# Table: postgres_resource
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT now()
#  project_id                  | uuid                     | NOT NULL
#  name                        | text                     | NOT NULL
#  target_vm_size              | text                     | NOT NULL
#  target_storage_size_gib     | bigint                   | NOT NULL
#  superuser_password          | text                     | NOT NULL
#  root_cert_1                 | text                     |
#  root_cert_key_1             | text                     |
#  server_cert                 | text                     |
#  server_cert_key             | text                     |
#  root_cert_2                 | text                     |
#  root_cert_key_2             | text                     |
#  certificate_last_checked_at | timestamp with time zone | NOT NULL DEFAULT now()
#  parent_id                   | uuid                     |
#  restore_target              | timestamp with time zone |
#  ha_type                     | ha_type                  | NOT NULL DEFAULT 'none'::ha_type
#  hostname_version            | hostname_version         | NOT NULL DEFAULT 'v1'::hostname_version
#  private_subnet_id           | uuid                     |
#  flavor                      | postgres_flavor          | NOT NULL DEFAULT 'standard'::postgres_flavor
#  location_id                 | uuid                     | NOT NULL
#  maintenance_window_start_at | integer                  |
#  user_config                 | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  pgbouncer_user_config       | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  tags                        | jsonb                    | NOT NULL DEFAULT '[]'::jsonb
#  target_version              | text                     | NOT NULL
#  trusted_ca_certs            | text                     |
#  cert_auth_users             | jsonb                    | NOT NULL DEFAULT '[]'::jsonb
# Indexes:
#  postgres_server_pkey                               | PRIMARY KEY btree (id)
#  postgres_resource_project_id_location_id_name_uidx | UNIQUE btree (project_id, location_id, name)
# Check constraints:
#  target_version_check               | (target_version = ANY (ARRAY['16'::text, '17'::text, '18'::text]))
#  valid_maintenance_windows_start_at | (maintenance_window_start_at >= 0 AND maintenance_window_start_at <= 23)
# Foreign key constraints:
#  postgres_resource_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_init_script        | postgres_init_script_id_fkey                          | (id) REFERENCES postgres_resource(id)
#  postgres_metric_destination | postgres_metric_destination_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
