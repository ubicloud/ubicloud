# frozen_string_literal: true

require_relative "../model"

class Firewall < Sequel::Model
  one_to_many :firewall_rules, key: :firewall_id
  many_to_many :private_subnets

  plugin :association_dependencies, firewall_rules: :destroy

  include ResourceMethods
  include Authorization::HyperTagMethods
  include ObjectTag::Cleanup
  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/firewall/#{name}"
  end

  dataset_module Pagination

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/firewall/#{name}"
  end

  def remove_firewall_rule(firewall_rule)
    firewall_rule.destroy
    private_subnets.map(&:incr_update_firewall_rules)
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

  def replace_firewall_rules(new_firewall_rules)
    firewall_rules.each(&:destroy)
    new_firewall_rules.each do |fwr|
      FirewallRule.create_with_id(
        firewall_id: id,
        cidr: fwr[:cidr],
        port_range: fwr[:port_range]
      )
    end

    private_subnets.each(&:incr_update_firewall_rules)
  end

  def before_destroy
    private_subnets.each(&:incr_update_firewall_rules)
    FirewallsPrivateSubnets.where(firewall_id: id).destroy
    super
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

# Table: firewall
# Columns:
#  id          | uuid                        | PRIMARY KEY
#  name        | text                        | NOT NULL DEFAULT 'Default'::text
#  description | text                        | NOT NULL DEFAULT 'Default firewall'::text
#  created_at  | timestamp without time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  location    | text                        | NOT NULL
#  project_id  | uuid                        |
# Indexes:
#  firewall_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  firewall_rule             | firewall_rule_firewall_id_fkey             | (firewall_id) REFERENCES firewall(id)
#  firewalls_private_subnets | firewalls_private_subnets_firewall_id_fkey | (firewall_id) REFERENCES firewall(id)
