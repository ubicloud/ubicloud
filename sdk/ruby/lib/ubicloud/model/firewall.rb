# frozen_string_literal: true

module Ubicloud
  class Firewall < Model
    set_prefix "fw"

    set_fragment "firewall"

    set_columns :id, :name, :description, :location, :firewall_rules, :path, :private_subnets

    set_associations do
      {private_subnets: PrivateSubnet}
    end

    def add_rule(cidr, start_port: nil, end_port: nil)
      adapter.post(path("/firewall-rule"), cidr:, port_range: "#{start_port || 0}..#{end_port || start_port || 65535}")
    end

    def delete_rule(rule_id)
      raise Error, "invalid rule id format" if rule_id.include?("/")
      adapter.delete(path("/firewall-rule/#{rule_id}"))
    end

    def attach_subnet(subnet)
      subnet_action(subnet, "/attach-subnet")
    end

    def detach_subnet(subnet)
      subnet_action(subnet, "/detach-subnet")
    end

    private

    def subnet_action(subnet, action)
      subnet = subnet.id if subnet.is_a?(PrivateSubnet)
      PrivateSubnet.new(adapter, adapter.post(path(action), private_subnet_id: subnet))
    end
  end
end
