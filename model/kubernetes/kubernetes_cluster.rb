#  frozen_string_literal: true

require_relative "../../model"

class KubernetesCluster < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :api_server_lb, class: :LoadBalancer
  many_to_one :private_subnet
  many_to_one :project
  many_to_many :cp_vms, join_table: :kubernetes_clusters_cp_vms, class: :Vm, order: :created_at
  one_to_many :nodepools, class: :KubernetesNodepool

  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  def validate
    super
    errors.add(:cp_node_count, "must be greater than 0") if cp_node_count <= 0
    errors.add(:version, "must be a valid Kubernetes version") unless ["v1.32", "v1.31"].include?(version)
  end

  def display_state
    return "deleting" if destroy_set? || strand.label == "destroy"
    return "running" if strand.label == "wait" && nodepools.all? { _1.strand.label == "wait" }
    "creating"
  end

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/kubernetes-cluster/#{name}"
  end

  def endpoint
    api_server_lb.hostname
  end

  def kubeconfig
    rbac_token = cp_vms.first.sshable.cmd("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system get secret k8s-access -o jsonpath='{.data.token}' | base64 -d")
    admin_kubeconfig = cp_vms.first.sshable.cmd("sudo cat /etc/kubernetes/admin.conf")
    kubeconfig = YAML.safe_load(admin_kubeconfig)
    kubeconfig["users"].each do |user|
      user["user"].delete("client-certificate-data")
      user["user"].delete("client-key-data")
      user["user"]["token"] = rbac_token
    end
    kubeconfig.to_yaml
  end
end

# Table: kubernetes_cluster
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  name              | text                     | NOT NULL
#  cp_node_count     | integer                  | NOT NULL
#  version           | text                     | NOT NULL
#  location          | text                     | NOT NULL
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id        | uuid                     | NOT NULL
#  private_subnet_id | uuid                     | NOT NULL
#  api_server_lb_id  | uuid                     |
# Indexes:
#  kubernetes_cluster_pkey                          | PRIMARY KEY btree (id)
#  kubernetes_cluster_project_id_location_name_uidx | UNIQUE btree (project_id, location, name)
# Foreign key constraints:
#  kubernetes_cluster_api_server_lb_id_fkey  | (api_server_lb_id) REFERENCES load_balancer(id)
#  kubernetes_cluster_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  kubernetes_cluster_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  kubernetes_clusters_cp_vms | kubernetes_clusters_cp_vms_kubernetes_cluster_id_fkey | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
#  kubernetes_nodepool        | kubernetes_nodepool_kubernetes_cluster_id_fkey        | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
