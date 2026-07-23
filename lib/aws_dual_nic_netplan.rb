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
module AwsDualNicNetplan
  # mgmt and user are DescribeNetworkInterfaces entries.
  def self.netplan(mgmt:, user:, subnet:, guardduty_ips: [], subnet6: nil)
    gw = subnet.nth(1).to_s
    mgmt_nic = {
      "match" => {"macaddress" => mgmt.mac_address},
      "dhcp4" => true,
      "dhcp4-overrides" => {"use-routes" => false},
      "routes" => [
        {"to" => subnet.to_s, "scope" => "link", "table" => 100},
        {"to" => "0.0.0.0/0", "via" => gw, "table" => 100},
      ],
      "routing-policy" => [{"from" => "#{mgmt.private_ip_address}/32", "table" => 100}] +
        guardduty_ips.map { {"to" => "#{it}/32", "table" => 100} },
    }
    user_nic = {
      "match" => {"macaddress" => user.mac_address},
      "dhcp4" => true,
      "routes" => [
        {"to" => subnet.to_s, "scope" => "link", "table" => 200},
        {"to" => "0.0.0.0/0", "via" => gw, "table" => 200},
      ],
      "routing-policy" => [{"from" => "#{user.private_ip_address}/32", "table" => 200}],
    }
    if subnet6
      mgmt_nic["dhcp6"] = true
      mgmt_nic["dhcp6-overrides"] = {"use-routes" => false}
      mgmt_nic["accept-ra"] = true
      mgmt_nic["routes"] << {"to" => subnet6.to_s, "scope" => "link", "table" => 100}
      mgmt_nic["routing-policy"] << {"from" => mgmt.ipv_6_addresses.first.ipv_6_address, "table" => 100}
      user_nic["dhcp6"] = true
      user_nic["accept-ra"] = true
    end
    to_quoted_yaml({"network" => {"version" => 2, "ethernets" => {"mgmt-nic" => mgmt_nic, "user-nic" => user_nic}}})
  end

  MAC_ADDRESS = /\A\h{2}(:\h{2}){5}\z/

  # Psych does not quote MAC addresses, and YAML 1.1 consumers read
  # all-digit MACs as sexagesimal integers; emit them double-quoted.
  def self.to_quoted_yaml(data)
    tree = Psych::Visitors::YAMLTree.create
    tree << data
    tree.tree.each do |node|
      node.style = Psych::Nodes::Scalar::DOUBLE_QUOTED if node.is_a?(Psych::Nodes::Scalar) && MAC_ADDRESS.match?(node.value)
    end
    tree.tree.yaml.delete_prefix("---\n")
  end

  NETWORKD_DROPINS = <<~SCRIPT
    mkdir -p /etc/systemd/network/10-netplan-mgmt-nic.network.d
    cat > /etc/systemd/network/10-netplan-mgmt-nic.network.d/10-ubicloud-ipv6.conf <<'CONF'
    [IPv6AcceptRA]
    RouteTable=100
    CONF
  SCRIPT

  def self.install_script(mgmt:, user:, subnet:, guardduty_ips: [], subnet6: nil)
    dropins = subnet6 ? NETWORKD_DROPINS : ""
    yaml = netplan(mgmt:, user:, subnet:, guardduty_ips:, subnet6:)
    <<~SCRIPT
      cat > /etc/netplan/61-ubicloud.yaml <<'NP'
      #{yaml.chomp}
      NP
      chmod 600 /etc/netplan/61-ubicloud.yaml
      #{dropins.chomp}
      netplan apply
    SCRIPT
  end
end
