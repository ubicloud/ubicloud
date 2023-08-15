# frozen_string_literal: true

class Prog::Vnet::SubnetNexus < Prog::Base
  subject_is :private_subnet
  semaphore :refresh_mesh, :destroy

  def self.assemble(project_id, name: nil, location: "hetzner-hel1", ipv6_range: nil, ipv4_range: nil)
    project = Project[project_id]
    unless project || Config.development?
      fail "No existing project"
    end

    ubid = PrivateSubnet.generate_ubid
    name ||= PrivateSubnet.ubid_to_name(ubid)

    Validation.validate_name(name)
    Validation.validate_location(location, project&.provider)

    ipv6_range ||= random_private_ipv6(location).to_s
    ipv4_range ||= random_private_ipv4(location).to_s
    DB.transaction do
      ps = PrivateSubnet.create(name: name, location: location, net6: ipv6_range, net4: ipv4_range, state: "waiting") { _1.id = ubid.to_uuid }
      ps.associate_with_project(project)
      Strand.create(prog: "Vnet::SubnetNexus", label: "wait") { _1.id = ubid.to_uuid }
    end
  end

  def wait
    when_destroy_set? do
      hop :destroy
    end

    when_refresh_mesh_set? do
      private_subnet.update(state: "refreshing_mesh")
      hop :refresh_mesh
    end

    nap 30
  end

  def refresh_mesh
    DB.transaction do
      private_subnet.nics.each do |nic|
        nic.update(encryption_key: "0x" + SecureRandom.bytes(36).unpack1("H*"))
        nic.incr_refresh_mesh
      end
    end

    hop :wait_refresh_mesh
  end

  def wait_refresh_mesh
    unless private_subnet.nics.any? { SemSnap.new(_1.id).set?("refresh_mesh") }
      DB.transaction do
        private_subnet.update(state: "waiting")
        private_subnet.nics.each do |nic|
          nic.update(encryption_key: nil)
        end

        decr_refresh_mesh
      end

      hop :wait
    end

    nap 1
  end

  def destroy
    if private_subnet.nics.any? { |n| !n.vm_id.nil? }
      fail "Cannot destroy subnet with active nics, first clean up the attached resources"
    end

    if private_subnet.nics.empty?
      DB.transaction do
        private_subnet.projects.each { |p| private_subnet.dissociate_with_project(p) }
        private_subnet.destroy
      end
      pop "subnet destroyed"
    else
      private_subnet.nics.map { |n| n.incr_destroy }
      nap 1
    end
  end

  def self.random_private_ipv6(location)
    network_address = NetAddr::IPv6.new((SecureRandom.bytes(7) + 0xfd.chr).unpack1("Q<") << 64)
    network_mask = NetAddr::Mask128.new(64)
    addr = NetAddr::IPv6Net.new(network_address, network_mask)
    return random_private_ipv6(location) unless PrivateSubnet.where(net6: addr.to_s, location: location).first.nil?

    addr
  end

  def self.random_private_ipv4(location)
    private_range = PrivateSubnet.random_subnet
    addr = NetAddr::IPv4Net.parse(private_range)

    selected_addr = addr.nth_subnet(26, SecureRandom.random_number(2**(26 - addr.netmask.prefix_len) - 1).to_i + 1)
    return random_private_ipv4(location) unless PrivateSubnet.where(net4: selected_addr.to_s, location: location).first.nil?

    selected_addr
  end
end
