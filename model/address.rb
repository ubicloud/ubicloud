# frozen_string_literal: true

require_relative "../model"

class Address < Sequel::Model
  one_to_many :assigned_vm_addresses, key: :address_id, class: :AssignedVmAddress
  one_to_many :assigned_host_addresses, key: :address_id, class: :AssignedHostAddress
  many_to_one :vm_host, key: :routed_to_host_id

  plugin ResourceMethods

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

  def after_create
    super
    populate_ipv4_addresses
  end

  def populate_ipv4_addresses
    # Do nothing for ipv6 addresses, since VM addresses are chosen randomly from the /64.
    # Ignore /32 IPv4 addresses, since those would be used by the host itself and not for
    # VMs running on the host.
    return unless cidr.is_a?(NetAddr::IPv4Net) && id != routed_to_host_id
    
    addresses = Array.new(cidr.len) { [cidr.nth(it), cidr.to_s] }

    if vm_host.provider_name == "leaseweb"
      # Do not use first or last addresses for leaseweb
      addresses.shift
      addresses.pop
    end

    DB[:ipv4_address].import([:ip, :cidr], addresses)
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
