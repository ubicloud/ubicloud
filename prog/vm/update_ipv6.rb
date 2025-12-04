# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Vm::UpdateIpv6 < Prog::Base
  subject_is :vm

  def vm_host
    @vm_host ||= VmHost[vm.vm_host_id]
  end

  def inhost_name
    @inhost_name ||= vm.inhost_name
  end

  label def start
    vm_host.sshable.cmd("sudo systemctl stop :inhost_name.service", inhost_name:)
    vm_host.sshable.cmd("sudo systemctl stop :inhost_name-metadata-endpoint.service", inhost_name:) if vm.load_balancer&.cert_enabled
    vm_host.sshable.cmd("sudo systemctl stop :inhost_name-dnsmasq.service", inhost_name:)
    vm_host.sshable.cmd("sudo ip netns del :inhost_name", inhost_name:)
    hop_rewrite_persisted
  end

  label def rewrite_persisted
    vm.update(
      ephemeral_net6: vm_host.ip6_random_vm_network.to_s
    )

    write_params_json
    vm_host.sshable.cmd("sudo host/bin/setup-vm reassign-ip6 :inhost_name", inhost_name:, stdin: JSON.generate({storage: vm.storage_secrets}))
    hop_start_vm
  end

  label def start_vm
    nic = vm.nics.first
    addr = nic.private_subnet.net4.nth(1).to_s + nic.private_subnet.net4.netmask.to_s

    vm_host.sshable.cmd("sudo ip -n :inhost_name addr replace :addr dev :tap_name", inhost_name:, addr:, tap_name: nic.ubid_to_tap_name)
    vm_host.sshable.cmd("sudo systemctl start :inhost_name-metadata-endpoint.service", inhost_name:) if vm.load_balancer&.cert_enabled
    vm.incr_update_firewall_rules
    vm.private_subnets.first.incr_refresh_keys
    pop "VM #{vm.name} updated"
  end

  def write_params_json
    vm_host.sshable.cmd("sudo rm /vm/:inhost_name/prep.json", inhost_name:)

    vm_host.sshable.cmd("sudo -u :inhost_name tee /vm/:inhost_name/prep.json", inhost_name:, stdin: vm.params_json(**vm.strand.stack.first.slice("swap_size_bytes", "hugepages", "hypervisor", "ch_version", "firmware_version").transform_keys!(&:to_sym)))
  end
end
