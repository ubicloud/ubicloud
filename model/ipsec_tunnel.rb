# frozen_string_literal: true

require_relative "../model"

class IpsecTunnel < Sequel::Model
  many_to_one :src_nic, key: :src_nic_id, class: Nic
  many_to_one :dst_nic, key: :dst_nic_id, class: Nic

  include ResourceMethods

  def vm_name(nic)
    nic.vm.inhost_name.shellescape
  end
end
