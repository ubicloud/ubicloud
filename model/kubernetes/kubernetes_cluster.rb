#  frozen_string_literal: true

require_relative "../../model"

class KubernetesCluster < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :api_server_lb, class: :LoadBalancer
  many_to_one :services_lb, class: :LoadBalancer
  many_to_one :private_subnet
  many_to_one :project
  many_to_many :cp_vms, join_table: :kubernetes_node, right_key: :vm_id, class: :Vm, order: :created_at, conditions: {kubernetes_nodepool_id: nil}
  one_to_many :nodes, class: :KubernetesNode, order: :created_at, conditions: {kubernetes_nodepool_id: nil}
  one_to_many :functional_nodes, class: :KubernetesNode, order: :created_at, conditions: {kubernetes_nodepool_id: nil, state: "active"}
  one_to_many :nodepools, class: :KubernetesNodepool
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, &:active
  many_to_one :location, key: :location_id

  dataset_module Pagination

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :sync_kubernetes_services, :upgrade, :install_metrics_server, :sync_worker_mesh, :install_csi, :update_billing_records
  include HealthMonitorMethods

  # :nocov:
  def self.add_internal_firewalls
    # Do not use transaction around the update of all resources, to avoid blocking
    all do |kc|
      next if kc.internal_cp_vm_firewall

      ubid = kc.ubid
      print "Adding internal firewalls for #{ubid}..."
      subnet = kc.private_subnet
      location_id = kc.location_id

      # Use transaction around the changes to each single postgres resource, because
      # we don't want a state where the internal firewall is created but not added
      # to the VMs, or where the preexisting firewall and private subnets do not both
      # get converted to the customer's project.
      DB.transaction do
        internal_cp_vm_firewall = Firewall.create(name: "#{ubid}-cp-vm-firewall", location_id:, description: "Kubernetes control plane node internal firewall", project_id: Config.kubernetes_service_project_id)
        internal_cp_vm_firewall.replace_firewall_rules([
          {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22..22)},
          {cidr: "::/0", port_range: Sequel.pg_range(22..22)},
          {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(443..443)},
          {cidr: "::/0", port_range: Sequel.pg_range(443..443)},
          {cidr: subnet.net4.to_s, port_range: Sequel.pg_range(10250..10250)},
          {cidr: subnet.net6.to_s, port_range: Sequel.pg_range(10250..10250)}
        ])

        # Internal worker node firewall, will be directly attached to kubernetes worker VMs
        internal_worker_vm_firewall = Firewall.create(name: "#{ubid}-worker-vm-firewall", location_id:, description: "Kubernetes worker node internal firewall", project_id: Config.kubernetes_service_project_id)
        internal_worker_vm_firewall.replace_firewall_rules([
          {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22..22)},
          {cidr: "::/0", port_range: Sequel.pg_range(22..22)},
          {cidr: subnet.net4.to_s, port_range: Sequel.pg_range(10250..10250)},
          {cidr: subnet.net6.to_s, port_range: Sequel.pg_range(10250..10250)}
        ])

        # Not strictly necessary to refresh the rules at this point,
        # since the rules in the existing firewall allow all traffic.
        # However, since the rules are different (even though traffic
        # allowed by the internal rules is allowed by the existing
        # firewall rules), probably best to refresh them.

        kc.cp_vms.each do |vm|
          vm.add_vm_firewall(internal_cp_vm_firewall)
          vm.incr_update_firewall_rules
        end

        kc.worker_vms.each do |vm|
          vm.add_vm_firewall(internal_worker_vm_firewall)
          vm.incr_update_firewall_rules
        end

        subnet.firewalls.each do |fw|
          fw.update(project_id: kc.project_id)
        end
        subnet.update(project_id: kc.project_id)

        puts "done"
      end
    end
  end
  # :nocov:

  def validate
    super
    errors.add(:cp_node_count, "must be a positive integer") unless cp_node_count.is_a?(Integer) && cp_node_count > 0
    errors.add(:version, "must be a valid Kubernetes version") unless Option.kubernetes_versions.include?(version)
  end

  def display_state
    label = strand.label
    return "deleting" if destroy_set? || label == "destroy"
    return "running" if label == "wait"

    "creating"
  end

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/kubernetes-cluster/#{name}"
  end

  def endpoint
    api_server_lb.hostname
  end

  def client(session: sshable.connect)
    Kubernetes::Client.new(self, session)
  end

  def sshable
    functional_nodes.first.sshable
  end

  def services_load_balancer_name
    "#{ubid}-services"
  end

  def apiserver_load_balancer_name
    "#{ubid}-apiserver"
  end

  def self.kubeconfig(vm)
    rbac_token = vm.sshable.cmd("kubectl --kubeconfig <(sudo cat /etc/kubernetes/admin.conf) -n kube-system get secret k8s-access -o jsonpath='{.data.token}' | base64 -d", log: false)
    admin_kubeconfig = vm.sshable.cmd("sudo cat /etc/kubernetes/admin.conf", log: false)
    kubeconfig = YAML.safe_load(admin_kubeconfig)
    kubeconfig["users"].each do |user|
      user["user"].delete("client-certificate-data")
      user["user"].delete("client-key-data")
      user["user"]["token"] = rbac_token
    end
    kubeconfig.to_yaml
  end

  def kubeconfig
    self.class.kubeconfig(cp_vms.first)
  end

  # Temporarily, kubernetes may not have internal firewalls, if they were
  # created before the customer firewall/internal firewalls split.
  def internal_cp_vm_firewall
    Firewall.first(project_id: Config.kubernetes_service_project_id, name: "#{ubid}-cp-vm-firewall")
  end

  def internal_worker_vm_firewall
    Firewall.first(project_id: Config.kubernetes_service_project_id, name: "#{ubid}-worker-vm-firewall")
  end

  def vm_diff_for_lb(load_balancer)
    worker_vms = nodepools.flat_map(&:vms)
    worker_vm_ids = worker_vms.map(&:id).to_set
    lb_vms = load_balancer.load_balancer_vms.map(&:vm)
    lb_vm_ids = lb_vms.map(&:id).to_set

    extra_vms = lb_vms.reject { |vm| worker_vm_ids.include?(vm.id) }
    missing_vms = worker_vms.reject { |vm| lb_vm_ids.include?(vm.id) }
    [extra_vms, missing_vms]
  end

  def port_diff_for_lb(load_balancer, desired_ports)
    lb_ports_hash = load_balancer.ports.to_h { |p| [[p.src_port, p.dst_port], p.id] }
    missing_ports = desired_ports - lb_ports_hash.keys
    extra_ports = (lb_ports_hash.keys - desired_ports).map { |p| LoadBalancerPort[id: lb_ports_hash[p]] }

    [extra_ports, missing_ports]
  end

  def init_health_monitor_session
    {
      ssh_session: sshable.start_fresh_session
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      incr_sync_kubernetes_services if client(session: session[:ssh_session]).any_lb_services_modified?
      "up"
    rescue
      "down"
    end
    aggregate_readings(previous_pulse: previous_pulse, reading: reading)
  end

  def install_rhizome
    cp_vms.each do |vm|
      Strand.create(prog: "InstallRhizome", label: "start", stack: [{subject_id: vm.sshable.id, target_folder: "kubernetes"}])
    end
  end

  def all_nodes
    nodes + nodepools.flat_map(&:nodes)
  end

  def worker_vms
    nodepools.flat_map(&:vms)
  end
end

# Table: kubernetes_cluster
# Columns:
#  id                           | uuid                     | PRIMARY KEY
#  name                         | text                     | NOT NULL
#  cp_node_count                | integer                  | NOT NULL
#  version                      | text                     | NOT NULL
#  created_at                   | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id                   | uuid                     | NOT NULL
#  private_subnet_id            | uuid                     | NOT NULL
#  api_server_lb_id             | uuid                     |
#  target_node_size             | text                     | NOT NULL
#  target_node_storage_size_gib | bigint                   |
#  location_id                  | uuid                     | NOT NULL
#  services_lb_id               | uuid                     |
# Indexes:
#  kubernetes_cluster_pkey                             | PRIMARY KEY btree (id)
#  kubernetes_cluster_project_id_location_id_name_uidx | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  kubernetes_cluster_api_server_lb_id_fkey  | (api_server_lb_id) REFERENCES load_balancer(id)
#  kubernetes_cluster_location_id_fkey       | (location_id) REFERENCES location(id)
#  kubernetes_cluster_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  kubernetes_cluster_project_id_fkey        | (project_id) REFERENCES project(id)
#  kubernetes_cluster_services_lb_id_fkey    | (services_lb_id) REFERENCES load_balancer(id)
# Referenced By:
#  kubernetes_node     | kubernetes_node_kubernetes_cluster_id_fkey     | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
#  kubernetes_nodepool | kubernetes_nodepool_kubernetes_cluster_id_fkey | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
