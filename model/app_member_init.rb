# frozen_string_literal: true

require_relative "../model"

class AppMemberInit < Sequel::Model
  many_to_one :app_process_member, read_only: true
  many_to_one :init_script_tag, read_only: true

  plugin ResourceMethods
end

# Table: app_member_init
# Columns:
#  id                    | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(640)
#  app_process_member_id | uuid | NOT NULL
#  init_script_tag_id    | uuid | NOT NULL
# Indexes:
#  app_member_init_pkey                                         | PRIMARY KEY btree (id)
#  app_member_init_app_process_member_id_init_script_tag_id_key | UNIQUE btree (app_process_member_id, init_script_tag_id)
#  app_member_init_app_process_member_id_index                  | btree (app_process_member_id)
# Foreign key constraints:
#  app_member_init_app_process_member_id_fkey | (app_process_member_id) REFERENCES app_process_member(id) ON DELETE CASCADE
#  app_member_init_init_script_tag_id_fkey    | (init_script_tag_id) REFERENCES init_script_tag(id)
