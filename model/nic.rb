# frozen_string_literal: true

require_relative "../model"

class Nic < Sequel::Model
  many_to_one :private_subnet
  many_to_one :vm
  one_to_many :src_ipsec_tunnels, key: :src_nic_id, class: :IpsecTunnel
  one_to_many :dst_ipsec_tunnels, key: :dst_nic_id, class: :IpsecTunnel
  one_to_one :strand, key: :id
  plugin :association_dependencies, src_ipsec_tunnels: :destroy, dst_ipsec_tunnels: :destroy

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :start_rekey, :trigger_outbound_update,
    :old_state_drop_trigger, :setup_nic, :repopulate

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
