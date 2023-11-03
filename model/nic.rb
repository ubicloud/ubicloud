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
  semaphore :destroy, :detach_vm, :start_rekey, :trigger_outbound_update,
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

  def add_firewall_rules
    rules = private_subnet.firewall_rules
    rule_cmds = "sudo ip netns exec #{vm.inhost_name} bash -c 'sudo nft add element inet fw_table allowed_ipv4_ips { #{rules.map { _1.start_ip4.to_s }.join(",")} }'"
    vm.vm_host.sshable.cmd(rule_cmds)
  end
end
