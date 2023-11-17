# frozen_string_literal: true

class Prog::Vnet::SubnetPeerNexus < Prog::Base
  subject_is :subnet_peer
  semaphore :destroy

  def self.assemble(provider_subnet_id, peer_subnet_id)
    unless (provider_subnet = PrivateSubnet[provider_subnet_id])
      fail "Given subnet doesn't exist with the id #{provider_subnet_id}"
    end
    unless (peer_subnet = PrivateSubnet[peer_subnet_id])
      fail "Given subnet doesn't exist with the id #{peer_subnet_id}"
    end

    ubid = SubnetPeer.generate_ubid
    DB.transaction do
      SubnetPeer.create(
        provider_subnet_id: provider_subnet.id,
        peer_subnet_id: peer_subnet.id
      ) { _1.id = ubid.to_uuid }
      Strand.create(prog: "Vnet::SubnetPeerNexus", label: "setup") { _1.id = ubid.to_uuid }
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy
    end
  end

  label def wait
    nap 60 unless subnet_peer.provider_subnet && subnet_peer.peer_subnet
    when_destroy_set? do
      hop_destroy
    end

    nap 1
  end

  def gen_encryption_key
    "0x" + SecureRandom.bytes(36).unpack1("H*")
  end

  def gen_spi
    "0x" + SecureRandom.bytes(4).unpack1("H*")
  end

  def gen_reqid
    SecureRandom.random_number(100000) + 1
  end

  label def setup
    src_nics = subnet_peer.provider_subnet.nics
    dst_nics = subnet_peer.peer_subnet.nics

    src_nics.each do |src_nic|
      dst_nics.each do |dst_nic|
        IpsecTunnel.create_with_id(
          src_nic_id: src_nic.id,
          dst_nic_id: dst_nic.id
        )
        IpsecTunnel.create_with_id(
          src_nic_id: dst_nic.id,
          dst_nic_id: src_nic.id
        )
        src_nic.encryption_key = gen_encryption_key
        dst_nic.encryption_key = src_nic.encryption_key
        src_nic.update(rekey_payload: {spi6: gen_spi, reqid: gen_reqid})
        dst_nic.update(rekey_payload: src_nic.rekey_payload)
        src_nic.private_subnet.incr_peered_tunnel_rekey
        dst_nic.private_subnet.incr_peered_tunnel_rekey
      end
    end

    hop_wait
  end
end
