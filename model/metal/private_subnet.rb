# frozen_string_literal: true

class PrivateSubnet < Sequel::Model
  module Metal
    def create_tunnels(nics, src_nic)
      nics.each do |dst_nic|
        next if src_nic == dst_nic

        IpsecTunnel.create(src_nic_id: src_nic.id, dst_nic_id: dst_nic.id) unless IpsecTunnel[src_nic_id: src_nic.id, dst_nic_id: dst_nic.id]
        IpsecTunnel.create(src_nic_id: dst_nic.id, dst_nic_id: src_nic.id) unless IpsecTunnel[src_nic_id: dst_nic.id, dst_nic_id: src_nic.id]
      end
    end

    def find_all_connected_nics
      Nic
        .where(private_subnet_id: DB[:subnet].exclude(:is_cycle).select(:id))
        .with_recursive(:subnet,
          this.select(:id),
          DB[:connected_subnet]
            .join(:subnet, {id: [:subnet_id_1, :subnet_id_2]})
            .select(Sequel.case({subnet_id_1: :subnet_id_2}, :subnet_id_1, Sequel[:subnet][:id])),
          cycle: {columns: :id})
    end

    private

    def metal_connect_subnet(subnet)
      ConnectedSubnet.create(subnet_hash(subnet))
      nics.each do |nic|
        create_tunnels(subnet.nics, nic)
      end
      subnet.incr_refresh_keys
    end

    def metal_disconnect_subnet(subnet)
      nics(eager: {src_ipsec_tunnels: [:src_nic, :dst_nic]}, dst_ipsec_tunnels: [:src_nic, :dst_nic]).each do |nic|
        (nic.src_ipsec_tunnels + nic.dst_ipsec_tunnels).each do |tunnel|
          tunnel.destroy if tunnel.src_nic.private_subnet_id == subnet.id || tunnel.dst_nic.private_subnet_id == subnet.id
        end
      end
      ConnectedSubnet.where(subnet_hash(subnet)).destroy
      subnet.incr_refresh_keys
      incr_refresh_keys
    end
  end
end
