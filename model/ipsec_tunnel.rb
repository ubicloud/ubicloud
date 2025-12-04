# frozen_string_literal: true

require_relative "../model"

class IpsecTunnel < Sequel::Model
  many_to_one :src_nic, key: :src_nic_id, class: :Nic
  many_to_one :dst_nic, key: :dst_nic_id, class: :Nic

  plugin ResourceMethods

  def vm_name(nic)
    nic.vm.inhost_name
  end
end

# Table: ipsec_tunnel
# Columns:
#  id         | uuid | PRIMARY KEY
#  src_nic_id | uuid |
#  dst_nic_id | uuid |
# Indexes:
#  ipsec_tunnel_pkey                      | PRIMARY KEY btree (id)
#  ipsec_tunnel_src_nic_id_dst_nic_id_key | UNIQUE btree (src_nic_id, dst_nic_id)
# Foreign key constraints:
#  ipsec_tunnel_dst_nic_id_fkey | (dst_nic_id) REFERENCES nic(id)
#  ipsec_tunnel_src_nic_id_fkey | (src_nic_id) REFERENCES nic(id)
