# frozen_string_literal: true

require "ulid"

class Prog::Vm::Nexus < Prog::Base
  def self.assemble(public_key, name: nil, size: "standard-4",
    unix_user: "ubi", location: "hetzner-hel1", boot_image: "ubuntu-jammy")
    DB.transaction do
      id = SecureRandom.uuid
      name ||= uuid_to_name(id)
      vm = Vm.create(public_key: public_key, unix_user: unix_user,
        name: name, size: size, location: location, boot_image: boot_image) { _1.id = id }
      Strand.create(prog: "Vm::Nexus", label: "start") { _1.id = vm.id }
    end
  end

  def self.uuid_to_name(id)
    "vm" + ULID.from_uuidish(id).to_s[0..5].downcase
  end

  def q_vm
    # YYY: various names in linux, like interface names, are obliged
    # to be short, so alas, probably can't reproduce entropy from
    # vm.id to be collision free and there will need to be a second
    # addressing scheme scoped to each VmHost.  But for now, assume
    # entropy.
    self.class.uuid_to_name(vm.id).shellescape
  end

  def vm
    @vm ||= Vm[strand.id]
  end

  def host
    @host ||= vm.vm_host
  end

  def unix_user
    @unix_user ||= vm.unix_user
  end

  def public_key
    @public_key ||= vm.public_key
  end

  def start
    # Prototype quality vm allocator: find least-used host to
    # demonstrate features that span hosts, because it ends up being
    # like round-robin in a non-concurrent allocation-only
    # demonstration.
    #
    # YYY: Lacks many necessary features like supporting different VM
    # sizes and preventing over-allocation.  The allocator should also
    # run in the strand of the host or do some other interlock to
    # avoid overbooking in concurrent scenarios, but that requires
    # more inter-strand synchronization than I want to do right now.
    vm_host_id = DB[<<SQL, vm.location].first[:id]
SELECT id
FROM (SELECT vm_host.id, count(*)
      FROM vm_host LEFT JOIN vm ON
      vm_host.id = vm.vm_host_id
      AND vm_host.allocation_state = 'accepting'
      AND vm_host.location = ?
      GROUP BY vm_host.id) AS counts
ORDER BY count
LIMIT 1
SQL

    vm.update(vm_host_id: vm_host_id, ephemeral_net6: VmHost[vm_host_id].ip6_random_vm_network.to_s)
    hop :prep
  end

  def prep
    q_net = vm.ephemeral_net6.to_s.shellescape
    host.sshable.cmd("sudo bin/prepvm.rb #{q_vm} #{q_net} #{unix_user.shellescape} #{public_key.shellescape} #{vm.boot_image.shellescape}")
    hop :run
  end

  def run
    host.sshable.cmd("sudo systemctl start #{q_vm}")
    vm.update(display_state: "running")
    hop :wait
  end

  def wait
  end
end
