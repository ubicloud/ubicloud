# frozen_string_literal: true

require_relative "../model"

class AppProcessInit < Sequel::Model
  many_to_one :app_process, read_only: true
  many_to_one :init_script_tag, read_only: true

  plugin ResourceMethods
end

# Table: app_process_init
# Columns:
#  id                 | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(321)
#  app_process_id     | uuid    | NOT NULL
#  init_script_tag_id | uuid    | NOT NULL
#  ordinal            | integer | NOT NULL
# Indexes:
#  app_process_init_pkey                                  | PRIMARY KEY btree (id)
#  app_process_init_app_process_id_init_script_tag_id_key | UNIQUE btree (app_process_id, init_script_tag_id)
#  app_process_init_app_process_id_ordinal_key            | UNIQUE btree (app_process_id, ordinal)
#  app_process_init_app_process_id_index                  | btree (app_process_id)
# Foreign key constraints:
#  app_process_init_app_process_id_fkey     | (app_process_id) REFERENCES app_process(id)
#  app_process_init_init_script_tag_id_fkey | (init_script_tag_id) REFERENCES init_script_tag(id)
