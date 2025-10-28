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
    def add_rule(cidr, start_port: nil, end_port: nil, description: nil)
      hash = {cidr:, port_range: "#{start_port || 0}..#{end_port || start_port || 65535}"}
      hash[:description] = description if description
      rule = adapter.post(_path("/firewall-rule"), **hash)

      self[:firewall_rules]&.<<(rule)

      rule
    end

    # Modify the firewall rule with the given id. At least one keyword argument is required.
    #
    # * If +start_port+ and +end_port+ are both given, they specify the updated port range.
    # * If only +start_port+ is given, the rule is updated to allow only that single port.
    # * If only +end_port+ is given, the rule is updated to allow all ports up to that port.
    # * If neither +start_port+ and +end_port+ are given, the port range is left unchanged.
    #
    # Returns a hash for the updated firewall rule.
    def modify_rule(rule_id, cidr: nil, start_port: nil, end_port: nil, description: nil)
      check_no_slash(rule_id, "invalid rule id format")

      hash = {cidr:, description:}
      hash.compact!
      if start_port || end_port
        hash[:port_range] = "#{start_port || 0}..#{end_port || start_port}"
      end

      if hash.empty?
        raise Error, "must provide at least one keyword argument"
      end

      rule = adapter.patch(_path("/firewall-rule/#{rule_id}"), **hash)

      self[:firewall_rules]&.find { it[:id] == rule_id }&.merge!(rule)

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
