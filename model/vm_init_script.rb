# frozen_string_literal: true

require_relative "../model"

class VmInitScript < Sequel::Model
end

# Table: vm_init_script
# Columns:
#  id         | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(53)
#  project_id | uuid | NOT NULL
#  name       | text | NOT NULL
#  script     | text | NOT NULL
# Indexes:
#  vm_init_script_pkey                | PRIMARY KEY btree (id)
#  vm_init_script_project_id_name_key | UNIQUE btree (project_id, name)
# Foreign key constraints:
#  vm_init_script_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  vm | vm_init_script_id_fkey | (init_script_id) REFERENCES vm_init_script(id)
