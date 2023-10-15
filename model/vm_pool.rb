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
      pick_vm_id_q = vms_dataset.left_join(:github_runner, vm_id: :id).where(Sequel[:github_runner][:vm_id] => nil, Sequel[:vm][:display_state] => "running").select(Sequel[:vm][:id])
      picked_vm = Vm.where(id: pick_vm_id_q).first
      return nil unless picked_vm

      picked_vm.dissociate_with_project(picked_vm.projects.first)
      picked_vm.private_subnets.each { |ps| ps.dissociate_with_project(picked_vm.projects.first) }

      # the billing records are updated here because the VM will be assigned
      # to a customer.
      picked_vm.active_billing_record.finalize(Time.now - 1)
      picked_vm.assigned_vm_address&.active_billing_record&.finalize(Time.now - 1)

      picked_vm
    end
  end
end
