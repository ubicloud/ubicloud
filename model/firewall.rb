# frozen_string_literal: true

require_relative "../model"

class Firewall < Sequel::Model
  one_to_many :firewall_rules, key: :firewall_id
  many_to_one :private_subnet, key: :private_subnet_id

  plugin :association_dependencies, firewall_rules: :destroy

  include ResourceMethods

  def insert_firewall_rule(cidr, port_range)
    fwr = FirewallRule.create_with_id(
      firewall_id: id,
      cidr: cidr,
      port_range: port_range
    )

    private_subnet&.incr_update_firewall_rules
    fwr
  end
end
