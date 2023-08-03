# frozen_string_literal: true

require_relative "../model"

class Nic < Sequel::Model
  many_to_one :private_subnet
  many_to_one :vm
  one_to_many :src_ipsec_tunnels, key: :src_nic_id, class: IpsecTunnel
  one_to_many :dst_ipsec_tunnels, key: :dst_nic_id, class: IpsecTunnel
  one_to_one :strand, key: :id, class: Strand
  include ResourceMethods
  include SemaphoreMethods
  semaphore :destroy, :refresh_mesh, :detach_vm, :start_rekey, :trigger_outbound_update, :old_state_drop_trigger

  plugin :column_encryption do |enc|
    enc.column :encryption_key
  end

  def self.ubid_to_name(ubid)
    ubid.to_s[0..7]
  end

  def ubid_to_tap_name
    ubid.to_s[0..9]
  end
end
