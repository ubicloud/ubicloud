# frozen_string_literal: true

require_relative "../model"

class FirewallRule < Sequel::Model
  many_to_one :firewall, key: :firewall_id

  include ResourceMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project)
    "project/#{project.ubid}/firewall/#{firewall.ubid}/firewall-rule/#{ubid}"
  end

  dataset_module Pagination
  dataset_module Authorization::Dataset

  def ip6?
    cidr.to_s.include?(":")
  end
end
