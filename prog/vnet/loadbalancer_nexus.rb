# frozen_string_literal: true

class Prog::Vnet::LoadbalancerNexus < Prog::Base
  subject_is :loadbalancer
  semaphore :destroy

  def self.assemble(project_id, subnet_id, location, name, vms)
    ubid = Nic.generate_ubid
    name ||= Nic.ubid_to_name(ubid)

    #subnet_st = Prog::Vnet::SubnetNexus.assemble(project_id, name: "#{name}-subnet", location: location)
    subnet = PrivateSubnet[subnet_id]
    ipv6_addr ||= subnet.random_private_ipv6.to_s
    ipv4_addr ||= subnet.random_private_ipv4.to_s

    DB.transaction do
      lb = Loadbalancer.create_with_id(name: name, ip_list: Sequel.lit("'{#{vms.map{ _1.ephemeral_net4.to_s }.to_s.gsub("\"", "")[1..-2]}}'"), vm_host_id: nil) { _1.id = ubid.to_uuid }
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
    loadbalancer.vm_host.sshable.cmd("sudo host/bin/create_loadbalancer #{loadbalancer.name} #{loadbalancer.assigned_address.ip.to_s} #{loadbalancer.ip_list.map(&:to_s)} ")
    hop_wait
  end

  label def wait
    nap 5
  end
end
