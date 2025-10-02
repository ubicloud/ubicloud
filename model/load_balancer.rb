#  frozen_string_literal: true

require_relative "../model"

class LoadBalancer < Sequel::Model
  many_to_one :project
  many_to_many :vms
  one_to_one :strand, key: :id
  many_to_one :private_subnet
  one_to_many :load_balancer_vms
  one_to_many :ports, class: :LoadBalancerPort
  many_to_many :certs
  one_to_many :load_balancer_certs
  many_to_one :custom_hostname_dns_zone, class: :DnsZone
  many_to_many :vm_ports, join_table: :load_balancer_port, right_key: :id, right_primary_key: :load_balancer_port_id, class: :LoadBalancerVmPort, read_only: true
  many_to_many :active_vm_ports, join_table: :load_balancer_port, right_key: :id, right_primary_key: :load_balancer_port_id, class: :LoadBalancerVmPort, read_only: true, conditions: {state: "up"}
  many_through_many :vms_to_dns, [[:load_balancer_port, :load_balancer_id, :id], [:load_balancer_vm_port, :load_balancer_port_id, :load_balancer_vm_id], [:load_balancers_vms, :id, :vm_id]], class: :Vm, conditions: Sequel.~(Sequel[:load_balancer_vm_port][:state] => ["evacuating", "detaching"])

  plugin :association_dependencies, load_balancer_vms: :destroy, ports: :destroy, load_balancer_certs: :destroy

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :update_load_balancer, :rewrite_dns_records, :refresh_cert
  include ObjectTag::Cleanup
  dataset_module Pagination

  def display_location
    private_subnet.display_location
  end

  def first_port
    ports.first
  end

  def src_port
    first_port&.src_port
  end

  def dst_port
    first_port&.dst_port
  end

  def health_check_url(use_endpoint: false, path: (health_check_endpoint if use_endpoint))
    "#{health_check_protocol}://#{hostname}#{":#{dst_port}" if use_endpoint}#{path}"
  end

  def path
    "/location/#{display_location}/load-balancer/#{name}"
  end

  def vm_ports_by_vm(vm)
    # Use subquery instead of joins as this is the basis for a dataset that will be used in an UPDATE query
    LoadBalancerVmPort.where(
      load_balancer_port_id: ports_dataset.select(:id),
      load_balancer_vm_id: vms_dataset.where(vm_id: vm.id).select(Sequel[:load_balancers_vms][:id])
    )
  end

  def vm_ports_by_vm_and_state(vm, state)
    vm_ports_by_vm(vm).where(state:)
  end

  def add_port(src_port, dst_port)
    DB.transaction do
      port = super(src_port:, dst_port:)
      load_balancer_vms.each do |lb_vm|
        LoadBalancerVmPort.create(load_balancer_port_id: port.id, load_balancer_vm_id: lb_vm.id)
      end
      incr_update_load_balancer
    end
  end

  def remove_port(port)
    DB.transaction do
      vm_ports_dataset.where(load_balancer_port_id: port.id).destroy
      ports_dataset.where(id: port.id).destroy
      incr_update_load_balancer
    end
  end

  def add_vm(vm)
    DB.transaction do
      load_balancer_vm = LoadBalancerVm.create(load_balancer_id: id, vm_id: vm.id)
      ports.each { |port|
        LoadBalancerVmPort.create(load_balancer_port_id: port.id, load_balancer_vm_id: load_balancer_vm.id)
      }
      setup_cert_server(vm.id) if cert_enabled
      incr_rewrite_dns_records
    end
  end

  def enable_cert_server
    vms.each { |vm| setup_cert_server(vm.id) }
  end

  def disable_cert_server
    vms.each { |vm| remove_cert_server(vm.id) }
    certs.each(&:incr_destroy)
  end

  def detach_vm(vm)
    DB.transaction do
      vm_ports_by_vm_and_state(vm, ["up", "down", "evacuating"]).update(state: "detaching")
      remove_cert_server(vm.id) if cert_enabled
      incr_update_load_balancer
    end
  end

  def evacuate_vm(vm)
    DB.transaction do
      vm_ports_by_vm_and_state(vm, ["up", "down"]).update(state: "evacuating")
      remove_cert_server(vm.id) if cert_enabled
      incr_update_load_balancer
      incr_rewrite_dns_records
    end
  end

  def remove_cert_server(vm_id)
    Strand.create(prog: "Vnet::CertServer", label: "remove_cert_server", stack: [{subject_id: id, vm_id:}], parent_id: id)
  end

  def setup_cert_server(vm_id)
    Strand.create(prog: "Vnet::CertServer", label: "setup_cert_server", stack: [{subject_id: id, vm_id:}], parent_id: id)
  end

  def remove_vm(vm)
    DB.transaction do
      vm_ports_by_vm(vm).destroy
      load_balancer_vms_dataset[vm_id: vm.id].destroy
      incr_rewrite_dns_records
    end
  end

  def remove_vm_port(vm_port)
    DB.transaction do
      vm_ports_dataset.where(Sequel[:load_balancer_vm_port][:id] => vm_port.id).destroy
      if vm_ports_dataset.where(load_balancer_vm_id: vm_port.load_balancer_vm_id).count.zero?
        load_balancer_vms_dataset[id: vm_port.load_balancer_vm_id].destroy
      end
      incr_rewrite_dns_records
    end
  end

  def hostname
    custom_hostname || "#{name}.#{private_subnet.ubid[-5...]}.#{Config.load_balancer_service_hostname}"
  end

  def dns_zone
    custom_hostname_dns_zone || DnsZone[project_id: Config.load_balancer_service_project_id, name: Config.load_balancer_service_hostname]
  end

  def need_certificates?
    return false unless cert_enabled

    certs_dataset.with_cert.needing_recert.empty?
  end

  def active_cert
    certs_dataset.with_cert.active.by_most_recent.first
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
#  id                          | uuid                     | PRIMARY KEY
#  name                        | text                     | NOT NULL
#  algorithm                   | lb_algorithm             | NOT NULL DEFAULT 'round_robin'::lb_algorithm
#  private_subnet_id           | uuid                     | NOT NULL
#  health_check_endpoint       | text                     | NOT NULL
#  health_check_interval       | integer                  | NOT NULL DEFAULT 10
#  health_check_timeout        | integer                  | NOT NULL DEFAULT 5
#  health_check_up_threshold   | integer                  | NOT NULL DEFAULT 5
#  health_check_down_threshold | integer                  | NOT NULL DEFAULT 3
#  health_check_protocol       | lb_hc_protocol           | NOT NULL DEFAULT 'http'::lb_hc_protocol
#  custom_hostname             | text                     |
#  custom_hostname_dns_zone_id | uuid                     |
#  stack                       | lb_stack                 | NOT NULL DEFAULT 'dual'::lb_stack
#  project_id                  | uuid                     | NOT NULL
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  cert_enabled                | boolean                  | DEFAULT false
# Indexes:
#  load_balancer_pkey                        | PRIMARY KEY btree (id)
#  load_balancer_custom_hostname_key         | UNIQUE btree (custom_hostname)
#  load_balancer_private_subnet_id_name_uidx | UNIQUE btree (private_subnet_id, name)
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
#  load_balancer_project_id_fkey                  | (project_id) REFERENCES project(id)
# Referenced By:
#  certs_load_balancers | certs_load_balancers_load_balancer_id_fkey | (load_balancer_id) REFERENCES load_balancer(id)
#  inference_endpoint   | inference_endpoint_load_balancer_id_fkey   | (load_balancer_id) REFERENCES load_balancer(id)
#  inference_router     | inference_router_load_balancer_id_fkey     | (load_balancer_id) REFERENCES load_balancer(id)
#  kubernetes_cluster   | kubernetes_cluster_api_server_lb_id_fkey   | (api_server_lb_id) REFERENCES load_balancer(id)
#  kubernetes_cluster   | kubernetes_cluster_services_lb_id_fkey     | (services_lb_id) REFERENCES load_balancer(id)
#  load_balancer_port   | load_balancer_port_load_balancer_id_fkey   | (load_balancer_id) REFERENCES load_balancer(id)
#  load_balancers_vms   | load_balancers_vms_load_balancer_id_fkey   | (load_balancer_id) REFERENCES load_balancer(id)
