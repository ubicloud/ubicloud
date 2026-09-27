# frozen_string_literal: true

# The ember side of a VmHost brought up with accepts_embers. An ember host is
# a VmHost that runs embers and nothing else, so everything here is worked out
# from the host's own row and what the control plane knows runs on it; none of
# it is stored.
class VmHostEmber
  # The oldest ubiblk embers run on, as VhostBlockBackend#version_code:
  # v0.5.1, until a release carries start_autofetch.
  MIN_UBIBLK_VERSION_CODE = 501

  attr_reader :vm_host

  def initialize(vm_host)
    @vm_host = vm_host
  end

  # The first /79 of the host's network that does not hold the host's own
  # address, one address per slot. Nothing else on an ember host is given
  # addresses, so there is nothing to keep clear of.
  def ip6_block
    reserved = vm_host.ip6_reserved_network
    [0, 1].map { NetAddr::IPv6Net.new(vm_host.net6.nth(it * 2**49), NetAddr::Mask128.new(79)) }
      .find { reserved.nil? || it.network.cmp(reserved.network) != 0 }
  end

  # As many slots as the host's memory holds, after 8 GiB for the host itself.
  # A slot costs its guest's memory, all of it resident once the guest has run,
  # plus about 30 MiB for its cloud-hypervisor and ubiblk processes, so a free
  # slot always has memory behind it and slots are the only capacity to track.
  def max_slots
    (vm_host.total_mem_gib - 8) * 1024 / (Config.ember_default_memory_mib + 32)
  end

  # The address of a slot, fixed for the host's lifetime, so a host's nftables
  # rules stay static.
  def slot_ip6(slot)
    raise ArgumentError, "slot #{slot} is out of range" if slot.negative? || slot >= max_slots
    ip6_block.nth(slot + 2).to_s
  end

  # Runs a host/bin/ember command. What the host needs to know about itself
  # travels with every call rather than living in a file on the host, the way
  # a VM's settings reach setup-vm.
  def cmd_json(command, stdin: {}, **)
    vm_host.sshable.cmd_json(command, stdin: {"host" => host_config}.merge(stdin).to_json, **)
  end

  def host_config
    {"max_slots" => max_slots, "ip6_block" => ip6_block.to_s, "ch_version" => Config.ember_ch_version,
     "ubiblk_version" => ubiblk_version}
  end

  # The newest ubiblk on the host that embers can run on.
  def ubiblk_version
    backend = vm_host.vhost_block_backends_dataset
      .where { version_code >= MIN_UBIBLK_VERSION_CODE }
      .order(:version_code).last
    fail "#{vm_host.ubid} has no ubiblk new enough for embers" unless backend
    backend.version
  end

  # Whether the host is answering, by the same monitor that watches every
  # VmHost: a host it has given up on is sent to unavailable.
  def available?
    vm_host.strand&.label != "unavailable" && !vm_host.checkup_set?(cached: false)
  end
end
