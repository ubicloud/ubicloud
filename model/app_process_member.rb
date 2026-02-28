# frozen_string_literal: true

require_relative "../model"

class AppProcessMember < Sequel::Model
  many_to_one :app_process, read_only: true
  many_to_one :vm, read_only: true
  one_to_many :app_member_inits, read_only: true

  plugin ResourceMethods
end

# Table: app_process_member
# Columns:
#  id             | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(340)
#  app_process_id | uuid    | NOT NULL
#  vm_id          | uuid    | NOT NULL
#  deploy_ordinal | integer |
#  ordinal        | integer | NOT NULL
#  state          | text    | NOT NULL DEFAULT 'active'::text
# Indexes:
#  app_process_member_pkey                       | PRIMARY KEY btree (id)
#  app_process_member_app_process_id_ordinal_key | UNIQUE btree (app_process_id, ordinal)
#  app_process_member_vm_id_key                  | UNIQUE btree (vm_id)
#  app_process_member_app_process_id_index       | btree (app_process_id)
# Foreign key constraints:
#  app_process_member_app_process_id_fkey | (app_process_id) REFERENCES app_process(id)
#  app_process_member_vm_id_fkey          | (vm_id) REFERENCES vm(id) ON DELETE CASCADE
# Referenced By:
#  app_member_init | app_member_init_app_process_member_id_fkey | (app_process_member_id) REFERENCES app_process_member(id) ON DELETE CASCADE
