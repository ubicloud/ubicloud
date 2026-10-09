# frozen_string_literal: true

# Netplan for dual-NIC GCE VMs. nic0 is the management NIC; the user NIC is
# the Dynamic NIC nic0.<vlan>, a VLAN on nic0 in the customer subnet. GCE's
# DHCP gives a default route only to nic0, so nic0 keeps its DHCP address
# but none of its routes. The main table holds the user NIC's default
# routes, so all VM-initiated traffic leaves through it, and from-source
# rules send each NIC's replies through its own table (mgmt 100, user 200).
# The metadata server, which also serves DNS and NTP, stays on nic0. GCE
# gives /32 addresses, so every IPv4 gateway is on-link. With mgmt_ipv6,
# nic0 also has an external IPv6 address for control plane SSH, with its
# default route only in the mgmt table.
#
# GCE assigns the MAC addresses and the external IPv6 addresses at
# instance creation, and the v1 API does not return them, so the
# template carries placeholders that the script fills from the metadata
# server at first boot.
GcpDualNicNetplan = Data.define(:mgmt_ip, :mgmt_gateway, :user_ip, :user_gateway, :mgmt_ipv6)

class GcpDualNicNetplan
  VLAN = 2
  MGMT_TABLE = 100
  USER_TABLE = 200
  # Ubicloud creates GCP VPCs with the default MTU.
  MTU = 1460
  METADATA_SERVER = "169.254.169.254"
  NETPLAN_PATH = "/etc/netplan/61-ubicloud.yaml"

  MGMT_MAC = "@MGMT_MAC@"
  MGMT_IPV6 = "@MGMT_IPV6@"
  MGMT_GATEWAY_IPV6 = "@MGMT_GATEWAY_IPV6@"
  USER_MAC = "@USER_MAC@"
  USER_IPV6 = "@USER_IPV6@"
  USER_GATEWAY_IPV6 = "@USER_GATEWAY_IPV6@"

  FILL_TEMPLATE = <<~PYTHON
    import ipaddress, json, os, re, time, urllib.request

    def metadata(path):
        url = "http://#{METADATA_SERVER}/computeMetadata/v1/instance/" + path + "/?recursive=true"
        for _ in range(60):
            try:
                req = urllib.request.Request(url, headers={"Metadata-Flavor": "Google"})
                with urllib.request.urlopen(req, timeout=2) as r:
                    return json.load(r)
            except Exception:
                time.sleep(2)
        raise SystemExit("metadata server did not answer for " + path)

    path = "#{NETPLAN_PATH}"
    with open(path + ".template") as f:
        text = f.read()

    nic0 = metadata("network-interfaces/0")
    user = metadata("vlan-network-interfaces/0/#{VLAN}")
    values = {
        "#{MGMT_MAC}": nic0["mac"],
        "#{USER_MAC}": user["mac"],
        "#{USER_IPV6}": str(ipaddress.IPv6Address(user["ipv6s"][0])),
        "#{USER_GATEWAY_IPV6}": str(ipaddress.IPv6Address(user["gatewayIpv6"])),
    }
    if "#{MGMT_IPV6}" in text:
        values["#{MGMT_IPV6}"] = str(ipaddress.IPv6Address(nic0["ipv6s"][0]))
        values["#{MGMT_GATEWAY_IPV6}"] = str(ipaddress.IPv6Address(nic0["gatewayIpv6"]))
    for key in ("#{MGMT_MAC}", "#{USER_MAC}"):
        if not re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", values[key]):
            raise SystemExit("unexpected MAC from metadata: " + values[key])

    for key, value in values.items():
        text = text.replace(key, value)
    with os.fdopen(os.open(path + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.rename(path + ".new", path)
    os.remove(path + ".template")
  PYTHON

  def to_yaml
    {
      "network" => {
        "version" => 2,
        "ethernets" => {"mgmt-nic" => mgmt_ethernet},
        "vlans" => {"user-nic" => user_vlan},
      },
    }.to_yaml.delete_prefix("---\n")
  end

  # Runs once at first boot. The files are synced before netplan apply:
  # files written without a sync come back empty after a hard reset. If the
  # metadata step fails, the script stops before it touches the network,
  # nic0 keeps the image's DHCP config, and the VM never gets past the
  # route check of the provisioning probe. No umask: netplan 1.2 writes the
  # networkd files with it, and systemd-networkd must be able to read them.
  def script
    <<~SCRIPT
      set -e
      echo #{NetSsh.command(":yaml", yaml: to_yaml.chomp)} > #{NETPLAN_PATH}.template
      python3 -c #{NetSsh.command(":code", code: FILL_TEMPLATE)}
      echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
      find /etc/netplan -maxdepth 1 -name '*.yaml' ! -name 61-ubicloud.yaml -delete
      sync
      netplan apply
    SCRIPT
  end

  private

  def mgmt_ethernet
    ethernet = {
      "match" => {"macaddress" => MGMT_MAC},
      "dhcp4" => true,
      "dhcp4-overrides" => {"use-routes" => false},
      "routes" => [
        {"to" => "#{METADATA_SERVER}/32", "via" => mgmt_gateway, "on-link" => true},
        {"to" => "0.0.0.0/0", "via" => mgmt_gateway, "on-link" => true, "table" => MGMT_TABLE},
      ],
      "routing-policy" => [{"from" => "#{mgmt_ip}/32", "table" => MGMT_TABLE}],
    }
    return ethernet unless mgmt_ipv6

    # A router advertisement would put an IPv6 default route on nic0 in the
    # main table, next to the user NIC's.
    ethernet["accept-ra"] = false
    ethernet["addresses"] = ["#{MGMT_IPV6}/128"]
    ethernet["routes"] << {"to" => "::/0", "via" => MGMT_GATEWAY_IPV6, "table" => MGMT_TABLE}
    ethernet["routing-policy"] << {"from" => "#{MGMT_IPV6}/128", "table" => MGMT_TABLE}
    ethernet
  end

  def user_vlan
    {
      "id" => VLAN,
      "link" => "mgmt-nic",
      "macaddress" => USER_MAC,
      "mtu" => MTU,
      "accept-ra" => false,
      "addresses" => ["#{user_ip}/32", "#{USER_IPV6}/128"],
      # The same routes in the main table and in the user table.
      "routes" => [{}, {"table" => USER_TABLE}].flat_map { |table|
        [
          {"to" => "0.0.0.0/0", "via" => user_gateway, "on-link" => true},
          {"to" => "::/0", "via" => USER_GATEWAY_IPV6},
        ].map { it.merge(table) }
      },
      "routing-policy" => [
        {"from" => "#{user_ip}/32", "table" => USER_TABLE},
        {"from" => "#{USER_IPV6}/128", "table" => USER_TABLE},
      ],
    }
  end
end
