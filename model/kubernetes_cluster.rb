#  frozen_string_literal: true

require_relative "../model"

class KubernetesCluster < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :load_balancer, key: :id, primary_key: :load_balancer_id
  one_to_one :private_subnet
  many_through_many :vms, [[:kubernetes_clusters_vm, :kubernetes_cluster_id, :vm_id]], class: :Vm do |ds|
    ds.order_by(:created_at)
  end
  one_to_many :kubernetes_nodepools

  plugin :association_dependencies, kubernetes_nodepools: :destroy

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  dataset_module Authorization::Dataset
  dataset_module Pagination
  semaphore :destroy, :upgrade

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
    load_balancer.hostname
  end

  def install_rhizome(sshable, install_specs: false)
    Strand.create_with_id(prog: "InstallRhizome", label: "start", stack: [{"target_folder" => "kubernetes", "subject_id" => sshable.id, "user" => sshable.unix_user}])
  end

  def kubeconfig
    vms.first.sshable.cmd("sudo cat /etc/kubernetes/admin.conf")
  end

  def kubectl(cmd)
    vms.first.sshable.cmd("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf #{cmd}")
  end
end
