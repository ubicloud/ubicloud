# frozen_string_literal: true

GcpDualNicNetplan = Data.define(:mgmt_ip, :mgmt_gateway, :user_ip, :user_gateway, :mgmt_ipv6)

class GcpDualNicNetplan
  VLAN = 2
  MGMT_TABLE = 100
  USER_TABLE = 200
  MTU = 1460
  METADATA_SERVER = "169.254.169.254"
  NETPLAN_PATH = "/etc/netplan/61-ubicloud.yaml"

  MGMT_MAC = "@MGMT_MAC@"
  MGMT_IPV6 = "@MGMT_IPV6@"
  MGMT_GATEWAY_IPV6 = "@MGMT_GATEWAY_IPV6@"
  USER_MAC = "@USER_MAC@"
  USER_IPV6 = "@USER_IPV6@"
  USER_GATEWAY_IPV6 = "@USER_GATEWAY_IPV6@"

  FILL_TEMPLATE = <<~SHELL
    netplan=#{NETPLAN_PATH}
    metadata() {
      i=0
      while [ "$i" -lt 60 ]; do
        if value=$(curl -sf -m 2 -H Metadata-Flavor:Google "http://#{METADATA_SERVER}/computeMetadata/v1/instance/$1"); then
          printf '%s\\n' "$value" | head -n 1
          return
        fi
        i=$((i + 1))
        sleep 2
      done
      echo "metadata server did not answer for $1" >&2
      return 1
    }
    fill() {
      value=$(metadata "$2")
      if ! printf '%s\\n' "$value" | grep -Eqx "$3"; then
        echo "unexpected $2 from metadata: $value" >&2
        return 1
      fi
      sed -i "s/$1/$value/g" "$netplan.new"
    }
    mac='[0-9a-f]{2}(:[0-9a-f]{2}){5}'
    ipv6='[0-9a-f]*:[0-9a-f:]*'
    install -m 600 "$netplan.template" "$netplan.new"
    fill #{MGMT_MAC} network-interfaces/0/mac "$mac"
    fill #{USER_MAC} vlan-network-interfaces/0/#{VLAN}/mac "$mac"
    fill #{USER_IPV6} vlan-network-interfaces/0/#{VLAN}/ipv6s "$ipv6"
    fill #{USER_GATEWAY_IPV6} vlan-network-interfaces/0/#{VLAN}/gateway-ipv6 "$ipv6"
    if grep -q #{MGMT_IPV6} "$netplan.new"; then
      fill #{MGMT_IPV6} network-interfaces/0/ipv6s "$ipv6"
      fill #{MGMT_GATEWAY_IPV6} network-interfaces/0/gateway-ipv6 "$ipv6"
    fi
    sync "$netplan.new"
    mv "$netplan.new" "$netplan"
    rm "$netplan.template"
  SHELL

  def to_yaml
    {
      "network" => {
        "version" => 2,
        "ethernets" => {"mgmt-nic" => mgmt_ethernet},
        "vlans" => {"user-nic" => user_vlan},
      },
    }.to_yaml.delete_prefix("---\n")
  end

  def script
    <<~SCRIPT
      set -e
      echo #{NetSsh.command(":yaml", yaml: to_yaml.chomp)} > #{NETPLAN_PATH}.template
      #{FILL_TEMPLATE.chomp}
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
