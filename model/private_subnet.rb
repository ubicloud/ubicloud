# frozen_string_literal: true

require_relative "../model"

class PrivateSubnet < Sequel::Model
  many_to_many :vms, join_table: :nic, left_key: :private_subnet_id, right_key: :vm_id
  one_to_many :nics, key: :private_subnet_id
  one_to_one :strand, key: :id
  many_to_many :firewalls
  one_to_many :load_balancers

  PRIVATE_SUBNET_RANGES = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16"
  ].freeze

  BANNED_IPV4_SUBNETS = [
    NetAddr::IPv4Net.parse("172.16.0.0/16"),
    NetAddr::IPv4Net.parse("172.17.0.0/16"),
    NetAddr::IPv4Net.parse("172.18.0.0/16")
  ].freeze

  dataset_module Pagination
  dataset_module Authorization::Dataset
  include Authorization::HyperTagMethods
  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/private-subnet/#{name}"
  end

  include Authorization::TaggableMethods

  def destroy
    DB.transaction do
      FirewallsPrivateSubnets.where(private_subnet_id: id).all.each(&:destroy)
      super
    end
  end

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/private-subnet/#{name}"
  end

  include ResourceMethods

  def self.ubid_to_name(ubid)
    ubid.to_s[0..7]
  end

  def display_state
    (state == "waiting") ? "available" : state
  end

  include SemaphoreMethods
  semaphore :destroy, :refresh_keys, :add_new_nic, :update_firewall_rules

  def self.random_subnet
    subnet_dict = PRIVATE_SUBNET_RANGES.each_with_object({}) do |subnet, hash|
      prefix_length = Integer(subnet.split("/").last, 10)
      hash[subnet] = (2**16 + 2**12 + 2**8 - 2**prefix_length)
    end
    subnet_dict.max_by { |_, weight| rand**(1.0 / weight) }.first
  end

  # Here we are blocking the bottom 4 and top 1 addresses of each subnet
  # The bottom first address is called the network address, that must be
  # blocked since we use it for routing.
  # The very last address is blocked because typically it is used as the
  # broadcast address.
  # We further block the bottom 3 addresses for future proofing. We may
  # use it in future for some other purpose. AWS also does that. Here
  # is the source;
  # https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html
  def random_private_ipv4
    total_hosts = 2**(32 - net4.netmask.prefix_len) - 5
    random_offset = SecureRandom.random_number(total_hosts) + 4
    addr = net4.nth_subnet(32, random_offset)
    return random_private_ipv4 if nics.any? { |nic| nic.private_ipv4.to_s == addr.to_s }

    addr
  end

  def random_private_ipv6
    addr = net6.nth_subnet(79, SecureRandom.random_number(2**(79 - net6.netmask.prefix_len) - 2).to_i + 1)
    return random_private_ipv6 if nics.any? { |nic| nic.private_ipv6.to_s == addr.to_s }

    addr
  end
end
