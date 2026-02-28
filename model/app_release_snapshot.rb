# frozen_string_literal: true

require_relative "../model"

class AppReleaseSnapshot < Sequel::Model
  many_to_one :app_release, read_only: true
  many_to_one :app_process, read_only: true
  one_to_many :app_release_snapshot_inits, read_only: true

  plugin ResourceMethods
end

# Table: app_release_snapshot
# Columns:
#  id               | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(334)
#  app_release_id   | uuid    | NOT NULL
#  app_process_id   | uuid    | NOT NULL
#  deploy_ordinal   | integer | NOT NULL
#  umi_id           | uuid    |
#  init_script_hash | text    |
# Indexes:
#  app_release_snapshot_pkey                 | PRIMARY KEY btree (id)
#  app_release_snapshot_app_release_id_index | btree (app_release_id)
# Foreign key constraints:
#  app_release_snapshot_app_process_id_fkey | (app_process_id) REFERENCES app_process(id)
#  app_release_snapshot_app_release_id_fkey | (app_release_id) REFERENCES app_release(id)
# Referenced By:
#  app_release_snapshot_init | app_release_snapshot_init_app_release_snapshot_id_fkey | (app_release_snapshot_id) REFERENCES app_release_snapshot(id)
