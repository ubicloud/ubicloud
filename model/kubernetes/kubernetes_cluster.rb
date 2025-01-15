#  frozen_string_literal: true

require_relative "../../model"

class KubernetesCluster < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :api_server_lb, class: :LoadBalancer, key: :id, primary_key: :api_server_lb_id
  many_to_one :private_subnet
  many_to_one :project
  many_to_many :vms, order: :created_at

  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods

  semaphore :destroy

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/kubernetes-cluster/#{name}"
  end

  def path
    "/location/#{display_location}/kubernetes-cluster/#{name}"
  end

  def endpoint
    api_server_lb.hostname
  end

  def disassociate_vm(vm)
    DB[:kubernetes_clusters_vms].where(
      kubernetes_cluster_id: id,
      vm_id: vm.id
    ).delete
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
#  kubernetes_cluster_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  kubernetes_cluster_cp_node_count_check | (cp_node_count = ANY (ARRAY[1, 3]))
# Foreign key constraints:
#  kubernetes_cluster_api_server_lb_id_fkey  | (api_server_lb_id) REFERENCES load_balancer(id)
#  kubernetes_cluster_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  kubernetes_cluster_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  kubernetes_clusters_cp_vms | kubernetes_clusters_cp_vms_kubernetes_cluster_id_fkey | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
#  kubernetes_nodepool        | kubernetes_nodepool_kubernetes_cluster_id_fkey        | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
