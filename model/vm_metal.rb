# frozen_string_literal: true

require_relative "../model"

class VmMetal < Sequel::Model
  many_to_one :vm, key: :id, read_only: true, is_used: true
  plugin ResourceMethods, etc_type: true, encrypted_columns: [:fscrypt_key, :fscrypt_key_2]
end

# Table: vm_metal
# Columns:
#  id            | uuid | PRIMARY KEY
#  fscrypt_key   | text |
#  fscrypt_key_2 | text |
# Indexes:
#  vm_metal_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  vm_metal_id_fkey | (id) REFERENCES vm(id)
