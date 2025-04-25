# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Vm::UpdateIpv6 < Prog::Base
  subject_is :vm

  def vm_host
    @vm_host ||= VmHost[vm.vm_host_id]
  end

  label def start
    vm_host.sshable.cmd("sudo systemctl stop #{vm.inhost_name}.service")
    vm_host.sshable.cmd("sudo systemctl stop #{vm.inhost_name}-dnsmasq.service")
    vm_host.sshable.cmd("sudo ip netns del #{vm.inhost_name}")
    hop_rewrite_persisted
  end

  label def rewrite_persisted
    vm.update(
      ephemeral_net6: vm_host.ip6_random_vm_network.to_s
    )

    write_params_json
    vm_host.sshable.cmd("sudo host/bin/setup-vm reassign-ip6 #{vm.inhost_name}#{Prog::Vm::Nexus::SETUP_VM_HUGEPAGES}", stdin: JSON.generate({storage: vm.storage_secrets}))
    hop_start_vm
  end

  label def start_vm
    nic = vm.nics.first
    addr = nic.private_subnet.net4.nth(1).to_s + nic.private_subnet.net4.netmask.to_s

    vm_host.sshable.cmd("sudo ip -n #{vm.inhost_name.shellescape} addr replace #{addr} dev #{nic.ubid_to_tap_name}")
    vm_host.sshable.cmd("sudo systemctl start #{vm.inhost_name}.service")
    vm.incr_update_firewall_rules
    pop "VM #{vm.name} updated"
  end

  def write_params_json
    vm_host.sshable.cmd("sudo rm /vm/#{vm.inhost_name}/prep.json")

    vm_host.sshable.cmd("sudo -u #{vm.inhost_name} tee /vm/#{vm.inhost_name}/prep.json", stdin: vm.params_json(nil))
  end
end
