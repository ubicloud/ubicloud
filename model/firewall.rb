# frozen_string_literal: true

require_relative "../model"

class Firewall < Sequel::Model
  one_to_many :firewall_rules, key: :firewall_id
  many_to_many :private_subnets

  plugin :association_dependencies, firewall_rules: :destroy

  include ResourceMethods
  include Authorization::TaggableMethods
  include Authorization::HyperTagMethods
  def hyper_tag_name(project)
    "project/#{project.ubid}/firewall/#{ubid}"
  end

  dataset_module Pagination
  dataset_module Authorization::Dataset

  def path
    "/firewall/#{ubid}"
  end

  def insert_firewall_rule(cidr, port_range)
    fwr = FirewallRule.create_with_id(
      firewall_id: id,
      cidr: cidr,
      port_range: port_range
    )

    private_subnets.each(&:incr_update_firewall_rules)
    fwr
  end

  def destroy
    DB.transaction do
      private_subnets.each(&:incr_update_firewall_rules)
      FirewallsPrivateSubnets.where(firewall_id: id).all.each(&:destroy)
      super
    end
  end

  def associate_with_private_subnet(private_subnet, apply_firewalls: true)
    add_private_subnet(private_subnet)
    private_subnet.incr_update_firewall_rules if apply_firewalls
  end

  def disassociate_from_private_subnet(private_subnet, apply_firewalls: true)
    FirewallsPrivateSubnets.where(
      private_subnet_id: private_subnet.id,
      firewall_id: id
    ).destroy

    private_subnet.incr_update_firewall_rules if apply_firewalls
  end
end
