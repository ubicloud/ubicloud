# frozen_string_literal: true

require_relative "../model"

class FirewallRule < Sequel::Model
  many_to_one :firewall, key: :firewall_id

  plugin ResourceMethods

  def ip6?
    cidr.to_s.include?(":")
  end

  def display_port_range
    port_range&.begin ? "#{port_range.begin}..#{port_range.end - 1}" : "0..65535"
  end
end

# Table: firewall_rule
# Columns:
#  id          | uuid      | PRIMARY KEY
#  cidr        | cidr      |
#  port_range  | int4range | DEFAULT '[0,65536)'::int4range
#  firewall_id | uuid      | NOT NULL
# Indexes:
#  firewall_rule_pkey                            | PRIMARY KEY btree (id)
#  firewall_rule_cidr_port_range_firewall_id_key | UNIQUE btree (cidr, port_range, firewall_id)
# Check constraints:
#  port_range_min_max | (lower(port_range) >= 0 AND upper(port_range) <= 65536)
# Foreign key constraints:
#  firewall_rule_firewall_id_fkey | (firewall_id) REFERENCES firewall(id)
