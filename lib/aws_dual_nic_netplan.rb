# frozen_string_literal: true

# Netplan for dual-NIC AWS VMs. Both NICs share a subnet, so from-source
# rules steer each NIC's replies through its own route table (mgmt 100,
# user 200) to keep flows symmetric, while the main table holds only the
# user NIC's default routes, sending all VM-initiated outbound through it.
# GuardDuty telemetry is the exception: to-rules pin the endpoint IPs to
# the mgmt NIC, IPv4 even in IPv6 mode.
#
# With subnet6 (postgres_aws_ssh_ipv6) the mgmt NIC has no EIP and is
# reached over its public IPv6. IPv6 default routes are learned from router
# advertisements (the fe80:: next-hop is unknowable at netplan-write time),
# so a networkd drop-in moves the mgmt NIC's RA-learned routes into table
# 100; netplan on Ubuntu 22.04 has no setting for the RA route table
# (newer releases do). Only the user NIC's IPv6 default route remains in
# the main table, so table 200 needs no IPv6 entries.
class AwsDualNicNetplan
  MGMT_TABLE = 100
  USER_TABLE = 200
  MAC_ADDRESS = /\A\h{2}(:\h{2}){5}\z/

  # mgmt and user are DescribeNetworkInterfaces entries.
  def initialize(mgmt:, user:, subnet:, guardduty_ips: [], subnet6: nil)
    @mgmt = mgmt
    @user = user
    @subnet = subnet
    @guardduty_ips = guardduty_ips
    @subnet6 = subnet6
  end

  def to_h
    {"network" => {"version" => 2, "ethernets" => {"mgmt-nic" => mgmt_ethernet, "user-nic" => user_ethernet}}}
  end

  def to_yaml
    to_quoted_yaml(to_h)
  end

  # RA-learned mgmt routes need moving to table 100 only in IPv6 mode; the
  # prog emits the networkd drop-in when this is true.
  def networkd_dropin?
    !@subnet6.nil?
  end

  private

  def gateway = @subnet.nth(1).to_s

  def mgmt_ethernet
    nic = {
      "match" => {"macaddress" => @mgmt.mac_address},
      "dhcp4" => true,
      "dhcp4-overrides" => {"use-routes" => false},
      "routes" => [
        {"to" => @subnet.to_s, "scope" => "link", "table" => MGMT_TABLE},
        {"to" => "0.0.0.0/0", "via" => gateway, "table" => MGMT_TABLE},
      ],
      "routing-policy" => [{"from" => "#{@mgmt.private_ip_address}/32", "table" => MGMT_TABLE}] +
        @guardduty_ips.map { {"to" => "#{it}/32", "table" => MGMT_TABLE} },
    }
    if @subnet6
      nic["dhcp6"] = true
      nic["dhcp6-overrides"] = {"use-routes" => false}
      nic["accept-ra"] = true
      nic["routes"] << {"to" => @subnet6.to_s, "scope" => "link", "table" => MGMT_TABLE}
      nic["routing-policy"] << {"from" => @mgmt.ipv_6_addresses.first.ipv_6_address, "table" => MGMT_TABLE}
    end
    nic
  end

  def user_ethernet
    nic = {
      "match" => {"macaddress" => @user.mac_address},
      "dhcp4" => true,
      "routes" => [
        {"to" => @subnet.to_s, "scope" => "link", "table" => USER_TABLE},
        {"to" => "0.0.0.0/0", "via" => gateway, "table" => USER_TABLE},
      ],
      "routing-policy" => [{"from" => "#{@user.private_ip_address}/32", "table" => USER_TABLE}],
    }
    if @subnet6
      nic["dhcp6"] = true
      nic["accept-ra"] = true
    end
    nic
  end

  # Psych does not quote MAC addresses, and YAML 1.1 consumers read
  # all-digit MACs as sexagesimal integers; emit them double-quoted.
  def to_quoted_yaml(data)
    tree = Psych::Visitors::YAMLTree.create
    tree << data
    tree.tree.each do |node|
      node.style = Psych::Nodes::Scalar::DOUBLE_QUOTED if node.is_a?(Psych::Nodes::Scalar) && MAC_ADDRESS.match?(node.value)
    end
    tree.tree.yaml.delete_prefix("---\n")
  end
end
