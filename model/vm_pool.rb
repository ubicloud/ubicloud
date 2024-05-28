# frozen_string_literal: true

require_relative "../model"

class VmPool < Sequel::Model
  one_to_one :strand, key: :id
  one_to_many :vms, key: :pool_id
  one_to_many :idle_vms, key: :pool_id, class: Vm, conditions: Sequel.&({tainted_at: nil}, Sequel.~(provisioned_at: nil))

  include ResourceMethods

  include SemaphoreMethods
  semaphore :destroy

  def pick_vm(new_name)
    vm_hash = DB[:vm]
      .returning
      .with(:candidate, idle_vms_dataset.limit(1))
      .from(:vm, :candidate)
      .where(Sequel[:vm][:id] => Sequel[:candidate][:id])
      .update(name: new_name, tainted_at: Time.now)
      .first

    Vm.call(vm_hash) unless vm_hash.nil?
  end
end
