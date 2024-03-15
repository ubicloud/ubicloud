# frozen_string_literal: true

class Prog::Vnet::LoadbalancerNexus < Prog::Base
  subject_is :loadbalancer
  semaphore :destroy

  def self.assemble(name, vms)
    ubid = Nic.generate_ubid
    name ||= Nic.ubid_to_name(ubid)

    ipv6_addr ||= subnet.random_private_ipv6.to_s
    ipv4_addr ||= subnet.random_private_ipv4.to_s

    DB.transaction do
      lb = Loadbalancer.create_with_id(name: name, ip_list: Sequel.pg_array(vms.map(&:ephemeral_net4), :inet))
      Strand.create(prog: "Vnet::LoadbalancerNexus", label: "start") { _1.id = lb.id }
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy"
    end
  end

  label def start
    vmh = VmHost.all.sample
    addr, addr_subnet  = vmh.ip4_random_vm_network
    AssignedVmAddress.create_with_id(ip: addr.to_s, loadbalancer_id: loadbalancer.id, address_id: addr_subnet.id)
    loadbalancer.update(vm_host_id: vmh.id)
    hop_setup_loadbalancer
  end

  label def setup_loadbalancer
    loadbalancer.vm_host.sshable.cmd("sudo host/bin/create_loadbalancer #{loadbalancer.name} #{loadbalancer.ip} ")
    hop_wait
  end

  label def wait
    nap 5
  end
end
