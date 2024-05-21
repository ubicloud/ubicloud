# frozen_string_literal: true

require_relative "../model"

class LoadBalancer < Sequel::Model
  many_to_many :vms
  many_to_many :active_vms, class: :Vm, left_key: :load_balancer_id, right_key: :vm_id, join_table: :load_balancers_vms, conditions: {state: "connected"}

  include ResourceMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  def hyper_tag_name(project)
    "project/#{project.ubid}/load-balancer/#{ubid}"
  end

  dataset_module Pagination
  dataset_module Authorization::Dataset

  def path
    "/load-balancer/#{ubid}"
  end
end
