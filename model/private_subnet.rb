# frozen_string_literal: true

require_relative "../model"

class PrivateSubnet < Sequel::Model
  many_to_many :vms, join_table: Nic.table_name, left_key: :private_subnet_id, right_key: :vm_id
  one_to_many :nics, key: :private_subnet_id
  one_to_one :strand, key: :id

  PRIVATE_SUBNET_RANGES = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16"
  ].freeze

  dataset_module Authorization::Dataset
  include Authorization::HyperTagMethods
  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/private-subnet/#{name}"
  end

  include Authorization::TaggableMethods

  def path
    "/location/#{location}/private-subnet/#{name}"
  end

  include ResourceMethods

  def self.ubid_to_name(ubid)
    ubid.to_s[0..7]
  end

  def display_state
    (state == "waiting") ? "available" : state
  end

  include SemaphoreMethods
  semaphore :destroy, :refresh_mesh

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
