#  frozen_string_literal: true

require_relative "../model"

class KubernetesVm < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :vm, key: :id, primary_key: :vm_id

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  dataset_module Authorization::Dataset
  dataset_module Pagination
  semaphore :destroy

  def display_location
    LocationNameConverter.to_display_name(vm.location)
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/kubernetes-vm/#{vm.name}"
  end

  def path
    "/location/#{display_location}/kubernetes-vm/#{vm.name}"
  end
end
