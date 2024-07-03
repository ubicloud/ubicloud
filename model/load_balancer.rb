#  frozen_string_literal: true

require_relative "../model"

class LoadBalancer < Sequel::Model
  many_to_many :vms
  one_to_one :strand, key: :id
  many_to_one :private_subnet
  one_to_many :projects, through: :private_subnet
  one_to_many :load_balancers_vms, key: :load_balancer_id, class: LoadBalancersVms

  plugin :association_dependencies, load_balancers_vms: :destroy

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  semaphore :destroy, :update_load_balancer

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{private_subnet.display_location}/load-balancer/#{name}"
  end

  def add_vm(vm)
    DB.transaction do
      super
      incr_update_load_balancer
    end
  end

  def detach_vm(vm)
    DB.transaction do
      DB[:load_balancers_vms].where(load_balancer_id: id, vm_id: vm.id).delete(force: true)
      incr_update_load_balancer
    end
  end
end
