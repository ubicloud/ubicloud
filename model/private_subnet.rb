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
  include Authorization::HyperTagMethods
  include ObjectTag::Cleanup
  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/private-subnet/#{name}"
  end

  def connected_subnets
    PrivateSubnet.where(
      id: DB[:connected_subnet].where(subnet_id_1: id).or(subnet_id_2: id).select(Sequel.case({{subnet_id_1: id} => :subnet_id_2}, :subnet_id_1)).all.map(&:values).flatten
    ).all
  end

  def all_nics
    nics + connected_subnets.flat_map(&:nics)
  end

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

  def connect_subnet(subnet)
    small_id_ps, large_id_ps = [self, subnet].sort_by(&:id)
    ConnectedSubnet.create_with_id(subnet_id_1: small_id_ps.id, subnet_id_2: large_id_ps.id)
    nics.each do |nic|
      create_tunnels(subnet.nics, nic)
    end
    subnet.incr_refresh_keys
  end

  def disconnect_subnet(subnet)
    small_id_ps, large_id_ps = [self, subnet].sort_by(&:id)
    nics.each do |nic|
      (nic.src_ipsec_tunnels + nic.dst_ipsec_tunnels).each do |tunnel|
        tunnel.destroy if tunnel.src_nic.private_subnet_id == subnet.id || tunnel.dst_nic.private_subnet_id == subnet.id
      end
    end
    ConnectedSubnet.where(subnet_id_1: small_id_ps.id, subnet_id_2: large_id_ps.id).all.map(&:destroy)
    subnet.incr_refresh_keys
    incr_refresh_keys
  end

  def create_tunnels(nics, src_nic)
    nics.each do |dst_nic|
      next if src_nic == dst_nic
      IpsecTunnel.create_with_id(src_nic_id: src_nic.id, dst_nic_id: dst_nic.id) unless IpsecTunnel[src_nic_id: src_nic.id, dst_nic_id: dst_nic.id]
      IpsecTunnel.create_with_id(src_nic_id: dst_nic.id, dst_nic_id: src_nic.id) unless IpsecTunnel[src_nic_id: dst_nic.id, dst_nic_id: src_nic.id]
    end
  end

  def find_all_connected_nics(excluded_private_subnet_ids = [])
    nics + connected_subnets.select { |subnet| !excluded_private_subnet_ids.include?(subnet.id) }.flat_map { _1.find_all_connected_nics(excluded_private_subnet_ids + [id]) }.uniq
  end
end

# Table: private_subnet
# Columns:
#  id            | uuid                     | PRIMARY KEY
#  net6          | cidr                     | NOT NULL
#  net4          | cidr                     | NOT NULL
#  state         | text                     | NOT NULL DEFAULT 'creating'::text
#  name          | text                     | NOT NULL
#  location      | text                     | NOT NULL
#  last_rekey_at | timestamp with time zone | NOT NULL DEFAULT now()
#  project_id    | uuid                     |
# Indexes:
#  vm_private_subnet_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  connected_subnet          | connected_subnet_subnet_id_1_fkey                | (subnet_id_1) REFERENCES private_subnet(id)
#  connected_subnet          | connected_subnet_subnet_id_2_fkey                | (subnet_id_2) REFERENCES private_subnet(id)
#  firewalls_private_subnets | firewalls_private_subnets_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  inference_endpoint        | inference_endpoint_private_subnet_id_fkey        | (private_subnet_id) REFERENCES private_subnet(id)
#  load_balancer             | load_balancer_private_subnet_id_fkey             | (private_subnet_id) REFERENCES private_subnet(id)
#  minio_cluster             | minio_cluster_private_subnet_id_fkey             | (private_subnet_id) REFERENCES private_subnet(id)
#  nic                       | nic_private_subnet_id_fkey                       | (private_subnet_id) REFERENCES private_subnet(id)
