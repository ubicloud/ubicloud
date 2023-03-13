# frozen_string_literal: true

require_relative "../model"

class VmHost < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :sshable, key: :id

  def host_prefix
    net6.netmask.prefix_len
  end

  # Compute the IPv6 Subnet that can be used to address the host
  # itself, and should not be delegated to any VMs.
  #
  # The default prefix length is 95, so that customers can be given a
  # /96 for their own exclusive use, and paired is the adjacent /96
  # for Clover's use on behalf of that VM.  This leaves 31 bits of
  # entropy relative to the customary /64 allocated to a real device.
  #
  # Offering a /96 to the VM renders nicely in the IPv6 format, as
  # it's 6 * 16, and each delimited part of IPv6 is 16 bits.
  def ip6_reserved_network(prefix = 95)
    fail "BUG" unless host_prefix < prefix
    NetAddr::IPv6Net.new(ip6, NetAddr::Mask128.new(prefix))
  end

  # Generate a random network that is a slice of the host's network
  # for delegation to a VM.
  def ip6_random_vm_network(prefix = 95)
    subnet_bits = prefix - host_prefix

    # If there was only one subnet bit, it would be allocated already
    # by ip6_reserved_network.
    fail "BUG" unless subnet_bits > 1

    # Perform integer division, rounding up the number of random bytes
    # needed.
    bytes_needed = ((subnet_bits - 1) / 8) + 1

    # Generate bits to sit between the host_prefix and the vm network.
    #
    # Shift them into the right place for a 128 bit IPv6 address
    lower_bits = SecureRandom.bytes(bytes_needed).unpack1("N") << (128 - prefix - 1)

    # Combine it with the higher bits for the host.
    proposal = NetAddr::IPv6Net.new(
      NetAddr::IPv6.new(net6.network.addr | lower_bits), NetAddr::Mask128.new(prefix)
    )

    fail "BUG: host should be supernet of randomized subnet" unless net6.rel(proposal) == 1

    # Guard against choosing the host-reserved network for a guest and
    # try again.  Recursion is used here because it's a likely code
    # path, and if there's a bug, it's better to stack overflow rather
    # than loop forever.
    ip6_random_vm_network(prefix) if proposal.network == ip6_reserved_network.network

    proposal
  end
end
