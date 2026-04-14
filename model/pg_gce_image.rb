# frozen_string_literal: true

require_relative "../model"

class PgGceImage < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: pg_gce_image
# Columns:
#  id             | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  gce_image_name | text | NOT NULL
#  arch           | text | NOT NULL
# Indexes:
#  pg_gce_image_pkey                      | PRIMARY KEY btree (id)
#  pg_gce_image_arch_gce_image_name_index | UNIQUE btree (arch, gce_image_name)
