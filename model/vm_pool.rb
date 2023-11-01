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
