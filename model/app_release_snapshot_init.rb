# frozen_string_literal: true

require_relative "../model"

class AppReleaseSnapshotInit < Sequel::Model
  many_to_one :app_release_snapshot, read_only: true
  many_to_one :init_script_tag, read_only: true

  plugin ResourceMethods
end

# Table: app_release_snapshot_init
# Columns:
#  id                      | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(769)
#  app_release_snapshot_id | uuid | NOT NULL
#  init_script_tag_id      | uuid | NOT NULL
# Indexes:
#  app_release_snapshot_init_pkey                                  | PRIMARY KEY btree (id)
#  app_release_snapshot_init_app_release_snapshot_id_init_scri_key | UNIQUE btree (app_release_snapshot_id, init_script_tag_id)
#  app_release_snapshot_init_app_release_snapshot_id_index         | btree (app_release_snapshot_id)
# Foreign key constraints:
#  app_release_snapshot_init_app_release_snapshot_id_fkey | (app_release_snapshot_id) REFERENCES app_release_snapshot(id)
#  app_release_snapshot_init_init_script_tag_id_fkey      | (init_script_tag_id) REFERENCES init_script_tag(id)
