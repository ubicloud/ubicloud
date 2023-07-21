# frozen_string_literal: true

require_relative "../model"

class PrivateSubnet < Sequel::Model
  many_to_many :vms, join_table: Nic.table_name, left_key: :private_subnet_id, right_key: :vm_id
  one_to_many :nics, key: :private_subnet_id
  one_to_one :strand, key: :id

  def self.uuid_to_name(id)
    "ps" + ULID.from_uuidish(id).to_s[0..8].downcase
  end

  dataset_module Authorization::Dataset
  include ResourceMethods

  def self.ubid_to_name(ubid)
    ubid.to_s[0..7]
  end

  def self.random_subnet
    PRIVATE_SUBNET_RANGES.sample
  end

  def random_private_ipv4
    addr = net4.nth_subnet(32, SecureRandom.random_number(2**(32 - net4.netmask.prefix_len) - 1))
    return random_private_ipv4 if nics.any? { |nic| nic.private_ipv4.to_s == addr.to_s }

    addr
  end

  def random_private_ipv6
    addr = net6.nth_subnet(79, SecureRandom.random_number(2**(79 - net6.netmask.prefix_len) - 1).to_i + 1)
    return random_private_ipv6 if nics.any? { |nic| nic.private_ipv6.to_s == addr.to_s }

    addr
  end

  def add_nic(nic)
    nics.each do |n|
      next if n.id == nic.id
      IpsecTunnel.create_with_id(src_nic_id: n.id, dst_nic_id: nic.id)
      IpsecTunnel.create_with_id(src_nic_id: nic.id, dst_nic_id: n.id)
    end
  end
end
