# frozen_string_literal: true

require_relative "../model"

class VmPool < Sequel::Model
  one_to_one :strand, key: :id
  one_to_many :vms, key: :pool_id

  include ResourceMethods

  include SemaphoreMethods
  semaphore :destroy

  def pick_vm
    DB.transaction do
      # first lock the whole pool in the join table so that no other thread can
      # pick a vm from this pool
      vms_dataset.for_update.all
      pick_vm_id_q = vms_dataset.left_join(:github_runner, vm_id: :id)
        .where(Sequel[:github_runner][:vm_id] => nil, Sequel[:vm][:display_state] => "running")
        .select(Sequel[:vm][:id])
      Vm.where(id: pick_vm_id_q).first
    end
  end
end

# Table: vm_pool
# Columns:
#  id                | uuid    | PRIMARY KEY
#  size              | integer | NOT NULL
#  vm_size           | text    | NOT NULL
#  boot_image        | text    | NOT NULL
#  location          | text    | NOT NULL
#  storage_size_gib  | bigint  | NOT NULL
#  arch              | arch    | NOT NULL DEFAULT 'x64'::arch
#  storage_encrypted | boolean | NOT NULL DEFAULT true
#  storage_skip_sync | boolean | NOT NULL DEFAULT false
# Indexes:
#  vm_pool_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  vm | vm_pool_id_fkey | (pool_id) REFERENCES vm_pool(id)
