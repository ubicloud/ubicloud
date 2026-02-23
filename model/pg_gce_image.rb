# frozen_string_literal: true

require_relative "../model"

class PgGceImage < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: pg_gce_image
# Columns:
#  id             | uuid | PRIMARY KEY
#  gcp_project_id | text | NOT NULL
#  gce_image_name | text | NOT NULL
#  pg_version     | text | NOT NULL
#  arch           | text | NOT NULL
# Indexes:
#  pg_gce_image_pkey                                 | PRIMARY KEY btree (id)
#  pg_gce_image_gcp_project_id_pg_version_arch_index | UNIQUE btree (gcp_project_id, pg_version, arch)
