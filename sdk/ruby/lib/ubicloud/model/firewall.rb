# frozen_string_literal: true

module Ubicloud
  class Firewall < Model
    set_prefix "fw"

    set_fragment "firewall"

    set_columns :id, :name, :description, :location, :firewall_rules, :path, :private_subnets

    set_associations do
      {private_subnets: PrivateSubnet}
    end

    # Allow the given cidr (ip address range) access to the given port range.
    #
    # * If +start_port+ and +end_port+ are both given, they specify the port range.
    # * If only +start_port+ is given, only that single port is allowed.
    # * If only +end_port+ is given, all ports up to that end port are allowed.
    # * If neither +start_port+ and +end_port+ are given, all ports are allowed.
    #
    # Returns a hash for the firewall rule.
    def add_rule(cidr, start_port: nil, end_port: nil)
      rule = adapter.post(_path("/firewall-rule"), cidr:, port_range: "#{start_port || 0}..#{end_port || start_port || 65535}")

      self[:firewall_rules]&.<<(rule)

      rule
    end

    # Delete the firewall rule with the given id.  Returns nil.
    def delete_rule(rule_id)
      check_no_slash(rule_id, "invalid rule id format")
      adapter.delete(_path("/firewall-rule/#{rule_id}"))

      self[:firewall_rules]&.delete_if { it[:id] == rule_id }

      nil
    end

    # Attach the given private subnet to the firewall. Accepts either a PrivateSubnet instance
    # or a private subnet id string.  Returns a PrivateSubnet instance.
    def attach_subnet(subnet)
      subnet_action(subnet, "/attach-subnet")
    end

    # Detach the given private subnet from the firewall. Accepts either a PrivateSubnet instance
    # or a private subnet id string.  Returns a PrivateSubnet instance.
    def detach_subnet(subnet)
      subnet_action(subnet, "/detach-subnet")
    end

    private

    # Internals of attach_subnet/detach_subnet.
    def subnet_action(subnet, action)
      PrivateSubnet.new(adapter, adapter.post(_path(action), private_subnet_id: to_id(subnet)))
    end
  end
end
