#  frozen_string_literal: true

require_relative "../model"

class LoadBalancer < Sequel::Model
  many_to_many :vms
  one_to_one :strand, key: :id

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  semaphore :destroy, :update_load_balancer, :rewrite_dns_records

  def hyper_tag_name(project)
    "project/#{project.ubid}/load-balancer/#{name}"
  end

  def add_vm(vm)
    DB.transaction do
      incr_update_load_balancer
      incr_rewrite_dns_records
      super
    end
  end

  def detach_vm(vm)
    DB.transaction do
      DB[:load_balancers_vms].where(load_balancer_id: id, vm_id: vm.id).delete(force: true)
      incr_update_load_balancer
      incr_rewrite_dns_records
    end
  end

  def hostname
    "#{name}.#{ubid[-5...]}.#{Config.load_balancer_service_hostname}"
  end
end
