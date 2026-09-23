# frozen_string_literal: true

require_relative "../model"

class Address < Sequel::Model
  one_to_many :assigned_host_addresses, read_only: true, is_used: true
  many_to_one :vm_host, key: :routed_to_host_id

  plugin ResourceMethods

  alias_method :admin_label, :cidr

  def validate
    super

    if new? && cidr.is_a?(NetAddr::IPv4Net) && cidr.len > 256
      errors.add(:cidr, "too large (contains more than 256 addresses)")
    end
  end

  def before_destroy
    DB[:ipv4_address].where(cidr:).delete
    super
  end

  # The caller decides which addresses open a VM pool; host-claimed ones,
  # recorded in assigned_host_address instead, never do. The provider names
  # the addresses of a block it reserves, such as its network and broadcast
  # addresses, and those stay out of the pool.
  def populate_ipv4_addresses(reserved: [])
    # ipv6 has no pool table; VM addresses are chosen randomly from the /64.
    return unless cidr.is_a?(NetAddr::IPv4Net)

    addresses = Array.new(cidr.len) { cidr.nth(it) }.reject { reserved.include?(it.to_s) }
    DB[:ipv4_address].import([:ip, :cidr], addresses.map { [it, cidr.to_s] })
  end
end

# Table: address
# Columns:
#  id                | uuid    | PRIMARY KEY
#  cidr              | cidr    | NOT NULL
#  is_failover_ip    | boolean | NOT NULL DEFAULT false
#  routed_to_host_id | uuid    | NOT NULL
# Indexes:
#  address_pkey     | PRIMARY KEY btree (id)
#  address_cidr_key | UNIQUE btree (cidr)
# Foreign key constraints:
#  address_routed_to_host_id_fkey | (routed_to_host_id) REFERENCES vm_host(id)
# Referenced By:
#  assigned_host_address | assigned_host_address_address_id_fkey | (address_id) REFERENCES address(id)
#  assigned_vm_address   | assigned_vm_address_address_id_fkey   | (address_id) REFERENCES address(id)
#  ipv4_address          | ipv4_address_cidr_fkey                | (cidr) REFERENCES address(cidr)
