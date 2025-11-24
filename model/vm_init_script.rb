# frozen_string_literal: true

require_relative "../model"

class VmInitScript < Sequel::Model
  plugin ResourceMethods, etc_type: true
end

# Table: vm_init_script
# Columns:
#  id          | uuid                    | PRIMARY KEY
#  script      | character varying(2000) | NOT NULL
#  init_script | text                    |
# Indexes:
#  vm_init_script_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  vm_init_script_id_fkey | (id) REFERENCES vm(id)
