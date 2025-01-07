#  frozen_string_literal: true

require_relative "../model"

class KubernetesNodepool < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :kubernetes_cluster
  many_through_many :vms, [[:kubernetes_nodepools_vm, :kubernetes_nodepool_id, :vm_id]], class: :Vm do |ds|
    ds.order_by(:created_at)
  end

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
    "project/#{project.ubid}/location/#{display_location}/kubernetes-nodepool/#{name}"
  end

  def path
    "/location/#{display_location}/kubernetes-nodepool/#{name}"
  end

  def install_rhizome(sshable, install_specs: false)
    Strand.create_with_id(prog: "InstallRhizome", label: "start", stack: [{"target_folder" => "kubernetes", "subject_id" => sshable.id, "user" => sshable.unix_user}])
  end
end
