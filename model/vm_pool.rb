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
      picked_vm = vms_dataset.for_update.where(display_state: "running").first
      return nil unless picked_vm

      picked_vm.dissociate_with_project(picked_vm.projects.first)
      picked_vm.private_subnets.each { |ps| ps.dissociate_with_project(picked_vm.projects.first) }

      # the billing records are updated here because the VM will be assigned
      # to a customer.
      picked_vm.active_billing_record.update(span: Sequel.pg_range(picked_vm.active_billing_record.span.begin...(Time.now - 1)))
      picked_vm.assigned_vm_address&.active_billing_record&.update(span: Sequel.pg_range(picked_vm.assigned_vm_address.active_billing_record.span.begin...(Time.now - 1)))

      # remove the VM from the pool
      picked_vm.update(pool_id: nil)
      picked_vm
    end
  end
end
