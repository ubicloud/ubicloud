# frozen_string_literal: true

require_relative "../model"

class FirewallRule < Sequel::Model
  plugin ResourceMethods

  def ip6?
    cidr.to_s.include?(":")
  end

  def display_port_range
    port_range&.begin ? "#{port_range.begin}..#{port_range.end - 1}" : "0..65535"
  end

  def <=>(other)
    (cidr.version <=> other.cidr.version).nonzero? ||
      (cidr.network.addr <=> other.cidr.network.addr).nonzero? ||
      (cidr.netmask.mask <=> other.cidr.netmask.mask).nonzero? ||
      (port_range.begin <=> other.port_range.begin).nonzero? ||
      port_range.end <=> other.port_range.end
  end
end

# Table: firewall_rule
# Columns:
#  id          | uuid      | PRIMARY KEY
#  cidr        | cidr      |
#  port_range  | int4range | DEFAULT '[0,65536)'::int4range
#  firewall_id | uuid      | NOT NULL
#  description | text      |
#  protocol    | text      | NOT NULL DEFAULT 'tcp'::text
# Indexes:
#  firewall_rule_pkey   | PRIMARY KEY btree (id)
#  firewall_rule_unique | UNIQUE btree (cidr, port_range, firewall_id, protocol)
# Check constraints:
#  port_range_min_max | (lower(port_range) >= 0 AND upper(port_range) <= 65536)
#  valid_protocol     | (protocol = ANY (ARRAY['tcp'::text, 'udp'::text]))
# Foreign key constraints:
#  firewall_rule_firewall_id_fkey | (firewall_id) REFERENCES firewall(id)
