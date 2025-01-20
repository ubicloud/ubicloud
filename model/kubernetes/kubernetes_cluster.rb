#  frozen_string_literal: true

require_relative "../../model"

class KubernetesCluster < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :api_server_lb, class: :LoadBalancer, key: :id, primary_key: :api_server_lb_id
  many_to_one :private_subnet
  many_to_one :project
  many_to_many :cp_vms, join_table: :kubernetes_clusters_cp_vms, class: :Vm, order: :created_at
  one_to_many :kubernetes_nodepools

  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :upgrade

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/kubernetes-cluster/#{name}"
  end

  def endpoint
    api_server_lb.hostname
  end

  def kubectl(cmd)
    cp_vms.first.sshable.cmd("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf #{cmd}")
  end

  def all_vms
    cp_vms + kubernetes_nodepools.flat_map(&:vms)
  end
end

# Table: kubernetes_cluster
# Columns:
#  id                 | uuid                        | PRIMARY KEY
#  name               | text                        | NOT NULL
#  cp_node_count      | integer                     | NOT NULL
#  kubernetes_version | text                        | NOT NULL
#  location           | text                        | NOT NULL
#  created_at         | timestamp without time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id         | uuid                        | NOT NULL
#  private_subnet_id  | uuid                        | NOT NULL
#  api_server_lb_id   | uuid                        |
# Indexes:
#  kubernetes_cluster_pkey                          | PRIMARY KEY btree (id)
#  kubernetes_cluster_project_id_location_name_uidx | UNIQUE btree (project_id, location, name)
# Check constraints:
#  kubernetes_cluster_cp_node_count_check | (cp_node_count = ANY (ARRAY[1, 3]))
# Foreign key constraints:
#  kubernetes_cluster_api_server_lb_id_fkey  | (api_server_lb_id) REFERENCES load_balancer(id)
#  kubernetes_cluster_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  kubernetes_cluster_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  kubernetes_clusters_cp_vms | kubernetes_clusters_cp_vms_kubernetes_cluster_id_fkey | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
#  kubernetes_nodepool        | kubernetes_nodepool_kubernetes_cluster_id_fkey        | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
