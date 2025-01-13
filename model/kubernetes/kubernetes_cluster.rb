#  frozen_string_literal: true

require_relative "../../model"

class KubernetesCluster < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :api_server_lb, class: :LoadBalancer
  many_to_one :private_subnet
  many_to_one :project
  many_to_many :cp_vms, join_table: :kubernetes_clusters_cp_vms, class: :Vm, order: :created_at

  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/kubernetes-cluster/#{name}"
  end

  def endpoint
    api_server_lb.hostname
  end
end

# Table: kubernetes_cluster
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  name              | text                     | NOT NULL
#  cp_node_count     | integer                  | NOT NULL
#  version           | kubernetes_version       | NOT NULL
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
