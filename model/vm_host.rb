# frozen_string_literal: true

require_relative "../model"

class VmHost < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :sshable, key: :id
  one_to_many :vms

  def host_prefix
    net6.netmask.prefix_len
  end

  # Compute the IPv6 Subnet that can be used to address the host
  # itself, and should not be delegated to any VMs.
  #
  # The default prefix length is 79, so that customers can be given a
  # /80 for their own exclusive use, and paired is the adjacent /80
  # for Clover's use on behalf of that VM.  This leaves 15 bits of
  # entropy relative to the customary /64 allocated to a real device.
  #
  # Offering a /80 to the VM renders nicely in the IPv6 format, as
  # it's 5 * 16, and each delimited part of IPv6 is 16 bits.
  #
  # A /80 is the longest prefix that is divisible by 16 and contains
  # multiple /96 subnets within it.  /96 is of special significance
  # because it contains enough space within it to hold the IPv4
  # address space, i.e. leaving the door open for schemes relying on
  # SIIT translation: https://datatracker.ietf.org/doc/html/rfc7915
  def ip6_reserved_network(prefix = 79)
    fail "BUG: host prefix must be is shorter than reserved prefix" unless host_prefix < prefix
    NetAddr::IPv6Net.new(ip6, NetAddr::Mask128.new(prefix))
  end

  # Generate a random network that is a slice of the host's network
  # for delegation to a VM.
  def ip6_random_vm_network(prefix = 79)
    subnet_bits = prefix - host_prefix

    # Perform integer division, rounding up the number of random bytes
    # needed.
    bytes_needed = ((subnet_bits - 1) / 8) + 1

    # Generate bits to sit between the host_prefix and the vm network.
    #
    # Shift them into the right place for a 128 bit IPv6 address
    lower_bits = SecureRandom.bytes(bytes_needed).unpack1("n") << (128 - prefix - 1)

    # Combine it with the higher bits for the host.
    proposal = NetAddr::IPv6Net.new(
      NetAddr::IPv6.new(net6.network.addr | lower_bits), NetAddr::Mask128.new(prefix)
    )

    # :nocov:
    fail "BUG: host should be supernet of randomized subnet" unless net6.rel(proposal) == 1
    # :nocov:

    case proposal.network.cmp(ip6_reserved_network.network)
    when 0
      # Guard against choosing the host-reserved network for a guest
      # and try again.  Recursion is used here because it's a likely
      # code path, and if there's a bug, it's better to stack overflow
      # rather than loop forever.
      ip6_random_vm_network(prefix)
    else
      proposal
    end
  end

  # Introduced for refreshing rhizome programs via REPL.
  def install_rhizome
    Strand.create(schedule: Time.now, prog: "InstallRhizome", label: "start", stack: [{subject_id: id}])
  end
end
