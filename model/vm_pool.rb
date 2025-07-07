# frozen_string_literal: true

require_relative "../model"

class VmPool < Sequel::Model
  one_to_one :strand, key: :id
  one_to_many :vms, key: :pool_id

  plugin ResourceMethods

  include SemaphoreMethods
  semaphore :destroy

  def pick_vm
    # Find an available VM in the "running" state and not associated with a GitHub runner,
    # and lock it with FOR NO KEY UPDATE SKIP LOCKED.
    vms_dataset
      .where(Sequel[:vm][:display_state] => "running")
      .exclude(id: DB[:github_runner].exclude(vm_id: nil).select(:vm_id))
      .for_no_key_update
      .skip_locked
      .first
  end
end

# Table: vm_pool
# Columns:
#  id                | uuid    | PRIMARY KEY
#  size              | integer | NOT NULL
#  vm_size           | text    | NOT NULL
#  boot_image        | text    | NOT NULL
#  storage_size_gib  | bigint  | NOT NULL
#  arch              | arch    | NOT NULL DEFAULT 'x64'::arch
#  storage_encrypted | boolean | NOT NULL DEFAULT true
#  storage_skip_sync | boolean | NOT NULL DEFAULT false
#  location_id       | uuid    | NOT NULL
# Indexes:
#  vm_pool_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  vm_pool_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  vm | vm_pool_id_fkey | (pool_id) REFERENCES vm_pool(id)
