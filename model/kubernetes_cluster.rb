#  frozen_string_literal: true

require_relative "../model"

class KubernetesCluster < Sequel::Model
  one_to_one :strand, key: :id
  one_to_many :kubernetes_nodepool

  plugin :association_dependencies, kubernetes_nodepool: :destroy

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  dataset_module Authorization::Dataset
  dataset_module Pagination
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
end
