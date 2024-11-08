#  frozen_string_literal: true

require_relative "../model"

class LoadBalancer < Sequel::Model
  many_to_many :vms
  many_to_many :active_vms, class: :Vm, left_key: :load_balancer_id, right_key: :vm_id, join_table: :load_balancers_vms, conditions: {state: ["up"]}
  many_to_many :vms_to_dns, class: :Vm, left_key: :load_balancer_id, right_key: :vm_id, join_table: :load_balancers_vms, conditions: Sequel.~(state: ["evacuating", "detaching"])
  one_to_one :strand, key: :id
  many_to_one :private_subnet
  one_to_many :projects, through: :private_subnet
  one_to_many :load_balancers_vms, key: :load_balancer_id, class: :LoadBalancersVms
  many_to_many :certs, join_table: :certs_load_balancers, left_key: :load_balancer_id, right_key: :cert_id
  one_to_many :certs_load_balancers, key: :load_balancer_id, class: :CertsLoadBalancers
  many_to_one :custom_hostname_dns_zone, class: :DnsZone, key: :custom_hostname_dns_zone_id

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
      Strand.create_with_id(prog: "Vnet::LoadBalancerHealthProbes", label: "health_probe", stack: [{subject_id: id, vm_id: vm.id}], parent_id: strand.id)
      Strand.create_with_id(prog: "Vnet::CertServer", label: "put_certificate", stack: [{subject_id: id, vm_id: vm.id}], parent_id: id)
      incr_rewrite_dns_records
    end
  end

  def detach_vm(vm)
    load_balancers_vms_dataset.where(vm_id: vm.id, state: ["up", "down", "evacuating"]).update(state: "detaching")
    Strand.create_with_id(prog: "Vnet::CertServer", label: "remove_cert_server", stack: [{subject_id: id, vm_id: vm.id}], parent_id: id)
    remove_health_probe(vm.id)
    incr_update_load_balancer
  end

  def evacuate_vm(vm)
    DB.transaction do
      load_balancers_vms_dataset.where(vm_id: vm.id, state: ["up", "down"]).update(state: "evacuating")
      remove_health_probe(vm.id)
      Strand.create_with_id(prog: "Vnet::CertServer", label: "remove_cert_server", stack: [{subject_id: id, vm_id: vm.id}], parent_id: id)
      incr_update_load_balancer
      incr_rewrite_dns_records
    end
  end

  def remove_vm(vm)
    load_balancers_vms_dataset[vm_id: vm.id].destroy
    incr_rewrite_dns_records
  end

  def remove_health_probe(vm_id)
    strand.children_dataset.where(prog: "Vnet::LoadBalancerHealthProbes").all.select { |st| st.stack[0]["subject_id"] == id && st.stack[0]["vm_id"] == vm_id }.map(&:destroy)
  end

  def hostname
    custom_hostname || "#{name}.#{private_subnet.ubid[-5...]}.#{Config.load_balancer_service_hostname}"
  end

  def dns_zone
    custom_hostname_dns_zone || DnsZone[project_id: Config.load_balancer_service_project_id, name: Config.load_balancer_service_hostname]
  end

  def need_certificates?
    return true if certs_dataset.empty?

    certs_dataset.where { created_at > Time.now - 60 * 60 * 24 * 30 * 2 }.empty?
  end

  def active_cert
    certs_dataset.where { created_at > Time.now - 60 * 60 * 24 * 30 * 3 }.order(Sequel.desc(:created_at)).first
  end

  def ipv4_enabled?
    stack == Stack::IPV4 || stack == Stack::DUAL
  end

  def ipv6_enabled?
    stack == Stack::IPV6 || stack == Stack::DUAL
  end

  module Stack
    IPV4 = "ipv4"
    IPV6 = "ipv6"
    DUAL = "dual"
  end
end

# Table: load_balancer
# Columns:
#  id                          | uuid           | PRIMARY KEY
#  name                        | text           | NOT NULL
#  algorithm                   | lb_algorithm   | NOT NULL DEFAULT 'round_robin'::lb_algorithm
#  src_port                    | integer        | NOT NULL
#  dst_port                    | integer        | NOT NULL
#  private_subnet_id           | uuid           | NOT NULL
#  health_check_endpoint       | text           | NOT NULL
#  health_check_interval       | integer        | NOT NULL DEFAULT 10
#  health_check_timeout        | integer        | NOT NULL DEFAULT 5
#  health_check_up_threshold   | integer        | NOT NULL DEFAULT 5
#  health_check_down_threshold | integer        | NOT NULL DEFAULT 3
#  health_check_protocol       | lb_hc_protocol | NOT NULL DEFAULT 'http'::lb_hc_protocol
#  custom_hostname             | text           |
#  custom_hostname_dns_zone_id | uuid           |
#  stack                       | lb_stack       | NOT NULL DEFAULT 'dual'::lb_stack
# Indexes:
#  load_balancer_pkey                | PRIMARY KEY btree (id)
#  load_balancer_custom_hostname_key | UNIQUE btree (custom_hostname)
# Check constraints:
#  health_check_down_threshold_gt_0              | (health_check_down_threshold > 0)
#  health_check_interval_gt_0                    | (health_check_interval > 0)
#  health_check_interval_lt_600                  | (health_check_interval < 600)
#  health_check_timeout_gt_0                     | (health_check_timeout > 0)
#  health_check_timeout_lt_health_check_interval | (health_check_timeout <= health_check_interval)
#  health_check_up_threshold_gt_0                | (health_check_up_threshold > 0)
# Foreign key constraints:
#  load_balancer_custom_hostname_dns_zone_id_fkey | (custom_hostname_dns_zone_id) REFERENCES dns_zone(id)
#  load_balancer_private_subnet_id_fkey           | (private_subnet_id) REFERENCES private_subnet(id)
# Referenced By:
#  certs_load_balancers | certs_load_balancers_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id)
#  inference_endpoint   | inference_endpoint_load_balancer_id_fkey   | (load_balancer_id) REFERENCES load_balancer(id)
#  load_balancers_vms   | load_balancers_vms_load_balancer_id_fkey   | (load_balancer_id) REFERENCES load_balancer(id)
