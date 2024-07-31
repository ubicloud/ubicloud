#  frozen_string_literal: true

require_relative "../model"

class LoadBalancer < Sequel::Model
  many_to_many :vms
  many_to_many :active_vms, class: :Vm, left_key: :load_balancer_id, right_key: :vm_id, join_table: :load_balancers_vms, conditions: {state: ["up"]}
  many_to_many :vms_to_dns, class: :Vm, left_key: :load_balancer_id, right_key: :vm_id, join_table: :load_balancers_vms, conditions: Sequel.~(state: "evacuating")
  one_to_one :strand, key: :id
  many_to_one :private_subnet
  one_to_many :projects, through: :private_subnet
  one_to_many :load_balancers_vms, key: :load_balancer_id, class: LoadBalancersVms
  many_to_many :certs, join_table: :certs_load_balancers, left_key: :load_balancer_id, right_key: :cert_id
  one_to_many :certs_load_balancers, key: :load_balancer_id, class: CertsLoadBalancers

  plugin :association_dependencies, load_balancers_vms: :destroy, certs_load_balancers: :destroy

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  dataset_module Authorization::Dataset
  dataset_module Pagination
  semaphore :destroy, :update_load_balancer, :rewrite_dns_records, :refresh_cert

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{private_subnet.display_location}/load-balancer/#{name}"
  end

  def path
    "/location/#{private_subnet.display_location}/load-balancer/#{name}"
  end

  def add_vm(vm)
    DB.transaction do
      super
      incr_update_load_balancer
      incr_rewrite_dns_records
    end
  end

  def evacuate_vm(vm)
    DB.transaction do
      load_balancers_vms_dataset.where(vm_id: vm.id).update(state: "evacuating")
      strand.children_dataset.where(prog: "Vnet::LoadBalancerHealthProbes").all.select { |st| st.stack[0]["subject_id"] == id && st.stack[0]["vm_id"] == vm.id }.map(&:destroy)
      incr_update_load_balancer
      incr_rewrite_dns_records
    end
  end

  def remove_vm(vm)
    load_balancers_vms_dataset.where(vm_id: vm.id).all.map(&:destroy)
  end

  def hostname
    "#{name}.#{private_subnet.ubid[-5...]}.#{Config.load_balancer_service_hostname}"
  end

  def need_certificates?
    return true if certs_dataset.empty?

    certs_dataset.where { created_at > Time.now - 60 * 60 * 24 * 30 * 2 }.empty?
  end

  def active_cert
    certs_dataset.where { created_at > Time.now - 60 * 60 * 24 * 30 * 3 }.order(Sequel.desc(:created_at)).first
  end
end
