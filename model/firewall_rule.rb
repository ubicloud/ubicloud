# frozen_string_literal: true

require_relative "../model"

class FirewallRule < Sequel::Model
  plugin ResourceMethods

  def ip6?
    cidr.to_s.include?(":")
  end

  def display_port_range
    return "0..65535" unless port_range
    begin_port = port_range.begin
    end_port = port_range.end
    end_port -= 1 if port_range.exclude_end?
    if begin_port == end_port
      begin_port.to_s
    else
      "#{begin_port}..#{end_port}"
    end
  end

  def web_display_cidr(ps_map)
    cidr_str = cidr.to_s
    ps_map[cidr_str] || DISPLAY_SOURCE_TYPE[cidr_str] || cidr_str.delete_suffix((cidr.version == 4) ? "/32" : "/128")
  end

  def web_display_port_range
    DISPLAY_PORT_NAMES[port_range&.to_range] || display_port_range
  end

  def <=>(other)
    (cidr.version <=> other.cidr.version).nonzero? ||
      (cidr.network.addr <=> other.cidr.network.addr).nonzero? ||
      (cidr.netmask.mask <=> other.cidr.netmask.mask).nonzero? ||
      (port_range.begin <=> other.port_range.begin).nonzero? ||
      port_range.end <=> other.port_range.end
  end

  # This is used for mapping port ranges to displayed names in the UI.
  DISPLAY_PORT_NAMES = {
    (22...23) => "SSH",
    (443...444) => "HTTPS",
    (5432...5433) => "PostgreSQL",
    (6432...6433) => "pgBouncer",
    (0...65536) => "All"
  }.freeze

  # This is used for mapping port ranges to select option values in the UI.
  PORT_TYPES = DISPLAY_PORT_NAMES.transform_values(&:downcase)
  PORT_TYPES.default = "custom"
  PORT_TYPES.freeze
  def port_type
    PORT_TYPES[port_range.to_range]
  end

  # This maps from select option values in the UI to port ranges. It is used during
  # form submissions to determine the underlying port range to use.
  PORT_RANGES = PORT_TYPES.invert.freeze
  def self.range_for_port_type(type)
    PORT_RANGES[type]
  end

  # This lists all allowed port select option values and text to display in the UI.
  PORT_OPTIONS = PORT_TYPES.values.zip(DISPLAY_PORT_NAMES.values)
  PORT_OPTIONS << ["custom", "Custom"]
  PORT_OPTIONS.freeze.each(&:freeze)
  def self.port_options
    PORT_OPTIONS
  end

  # This is used for mapping IP address ranges to displayed names in the UI.
  # Note that named private subnets are not handled by this.
  DISPLAY_SOURCE_TYPE = {
    "0.0.0.0/0" => "All IPv4",
    "::/0" => "All IPv6"
  }.freeze

  # This is used for mapping IP address ranges to select option values in the UI.
  SOURCE_TYPES = DISPLAY_SOURCE_TYPE.transform_values { it.downcase.sub(" ", "_") }
  SOURCE_TYPES.default = "custom"
  SOURCE_TYPES.freeze
  def source_type
    SOURCE_TYPES[cidr.to_s]
  end

  # This maps from select option values in the UI to IP address ranges. It is
  # used during form submissions to determine the underlying IP address range to use.
  SOURCE_CIDRS = SOURCE_TYPES.invert.freeze
  def self.cidr_for_source_type(type)
    SOURCE_CIDRS[type]
  end

  # This lists all allowed source select option values and text to display in the UI.
  SOURCE_OPTIONS = SOURCE_TYPES.values.zip(DISPLAY_SOURCE_TYPE.values)
  SOURCE_OPTIONS.push(
    ["subnet4", "Private Subnet IPv4"],
    ["subnet6", "Private Subnet IPv6"],
    ["custom", "Custom"]
  )
  SOURCE_OPTIONS.freeze.each(&:freeze)
  def self.source_options
    SOURCE_OPTIONS
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
