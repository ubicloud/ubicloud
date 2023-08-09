# frozen_string_literal: true

class Prog::Vnet::NicNexus < Prog::Base
  semaphore :destroy, :refresh_mesh, :detach_vm

  def self.assemble(private_subnet_id, name: nil, ipv6_addr: nil, ipv4_addr: nil)
    unless (subnet = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    ubid = Nic.generate_ubid
    name ||= Nic.ubid_to_name(ubid)

    ipv6_addr ||= subnet.random_private_ipv6.to_s
    ipv4_addr ||= subnet.random_private_ipv4.to_s

    DB.transaction do
      nic = Nic.create(private_ipv6: ipv6_addr, private_ipv4: ipv4_addr, mac: gen_mac,
        name: name, private_subnet_id: private_subnet_id) { _1.id = ubid.to_uuid }
      subnet.add_nic(nic)
      Strand.create(prog: "Vnet::NicNexus", label: "wait") { _1.id = ubid.to_uuid }
    end
  end

  def nic
    @nic ||= Nic[strand.id]
  end

  def before_run
    when_destroy_set? do
      hop :destroy if strand.label != "destroy"
    end
  end

  def wait
    when_refresh_mesh_set? do
      hop :refresh_mesh
    end

    when_detach_vm_set? do
      hop :detach_vm
    end

    nap 30
  end

  def refresh_mesh
    if nic.vm_id.nil?
      decr_refresh_mesh
      hop :wait
    end

    nic.src_ipsec_tunnels.each do |tunnel|
      tunnel.refresh
    end

    decr_refresh_mesh
    hop :wait
  end

  def destroy
    if nic.vm
      fail "Cannot destroy nic with active vm, first clean up the attached resources"
    end

    DB.transaction do
      nic.src_ipsec_tunnels_dataset.destroy
      nic.dst_ipsec_tunnels_dataset.destroy
      nic.private_subnet.incr_refresh_mesh
      nic.destroy
    end

    pop "nic deleted"
  end

  def detach_vm
    DB.transaction do
      nic.update(vm_id: nil)
      nic.src_ipsec_tunnels_dataset.destroy
      nic.dst_ipsec_tunnels_dataset.destroy
      nic.private_subnet.incr_refresh_mesh
      decr_detach_vm
    end

    hop :wait
  end

  # Generate a MAC with the "local" (generated, non-manufacturer) bit
  # set and the multicast bit cleared in the first octet.
  #
  # Accuracy here is not a formality: otherwise assigning a ipv6 link
  # local address errors out.
  def self.gen_mac
    ([rand(256) & 0xFE | 0x02] + Array.new(5) { rand(256) }).map {
      "%0.2X" % _1
    }.join(":").downcase
  end
end
