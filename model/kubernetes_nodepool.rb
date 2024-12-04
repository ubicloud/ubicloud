#  frozen_string_literal: true

require_relative "../model"

class KubernetesNodepool < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :kubernetes_cluster

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  dataset_module Authorization::Dataset
  dataset_module Pagination
  semaphore :destroy

  # def hyper_tag_name(project)
  #   "project/#{project.ubid}/location/#{}/kubernetes-nodepool/#{name}"
  # end

  # def path
  #   "/location/#{}/kubernetes-nodepool/#{name}"
  # end
end
