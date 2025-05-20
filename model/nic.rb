# frozen_string_literal: true

require_relative "../model"

class Nic < Sequel::Model
  many_to_one :private_subnet
  many_to_one :vm
  one_to_many :src_ipsec_tunnels, key: :src_nic_id, class: :IpsecTunnel
  one_to_many :dst_ipsec_tunnels, key: :dst_nic_id, class: :IpsecTunnel
  one_to_one :strand, key: :id
  one_to_one :nic_aws_resource, key: :id
  plugin :association_dependencies, src_ipsec_tunnels: :destroy, dst_ipsec_tunnels: :destroy, nic_aws_resource: :destroy

  plugin ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :start_rekey, :trigger_outbound_update,
    :old_state_drop_trigger, :setup_nic, :repopulate, :lock, :vm_allocated

  plugin :column_encryption do |enc|
    enc.column :encryption_key
  end

  def self.ubid_to_name(ubid)
    ubid.to_s[0..7]
  end

  def ubid_to_tap_name
    ubid.to_s[0..9]
  end

  def private_ipv4_gateway
    private_subnet.net4.nth(1).to_s + private_subnet.net4.netmask.to_s
  end

  def unlock
    Semaphore.where(strand_id: strand.id, name: "lock").delete(force: true)
  end
end

# Table: nic
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  private_subnet_id | uuid                     | NOT NULL
#  mac               | macaddr                  | NOT NULL
#  created_at        | timestamp with time zone | NOT NULL DEFAULT now()
#  private_ipv4      | cidr                     | NOT NULL
#  private_ipv6      | cidr                     | NOT NULL
#  vm_id             | uuid                     |
#  encryption_key    | text                     |
#  name              | text                     | NOT NULL
#  rekey_payload     | jsonb                    |
# Indexes:
#  nic_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  nic_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  nic_vm_id_fkey             | (vm_id) REFERENCES vm(id)
# Referenced By:
#  ipsec_tunnel     | ipsec_tunnel_dst_nic_id_fkey | (dst_nic_id) REFERENCES nic(id)
#  ipsec_tunnel     | ipsec_tunnel_src_nic_id_fkey | (src_nic_id) REFERENCES nic(id)
#  nic_aws_resource | nic_aws_resource_id_fkey     | (id) REFERENCES nic(id)
