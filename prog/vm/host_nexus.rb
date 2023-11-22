# frozen_string_literal: true

class Prog::Vm::HostNexus < Prog::Base
  subject_is :sshable, :vm_host
  semaphore :reboot, :destroy

  def self.assemble(sshable_hostname, location: "hetzner-hel1", net6: nil, ndp_needed: false, provider: nil, hetzner_server_identifier: nil, spdk_version: Config.spdk_version)
    DB.transaction do
      ubid = VmHost.generate_ubid

      Sshable.create(host: sshable_hostname) { _1.id = ubid.to_uuid }
      vmh = VmHost.create(location: location, net6: net6, ndp_needed: ndp_needed) { _1.id = ubid.to_uuid }

      if provider == HetznerHost::PROVIDER_NAME
        HetznerHost.create(server_identifier: hetzner_server_identifier) { _1.id = vmh.id }
        vmh.create_addresses
        vmh.set_data_center
      else
        Address.create(cidr: sshable_hostname, routed_to_host_id: vmh.id) { _1.id = vmh.id }
        AssignedHostAddress.create_with_id(ip: sshable_hostname, address_id: vmh.id, host_id: vmh.id)
      end

      Strand.create(
        prog: "Vm::HostNexus",
        label: "start",
        stack: [{"spdk_version" => spdk_version}]
      ) { _1.id = vmh.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    register_deadline(:wait, 15 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "host"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_prep if leaf?
    donate
  end

  label def prep
    bud Prog::Vm::PrepHost
    bud Prog::LearnNetwork unless vm_host.net6
    bud Prog::LearnMemory
    bud Prog::LearnArch
    bud Prog::LearnCores
    bud Prog::LearnStorage
    bud Prog::InstallDnsmasq
    bud Prog::SetupSysstat
    hop_wait_prep
  end

  label def wait_prep
    reap.each do |st|
      case st.prog
      when "LearnArch"
        vm_host.update(arch: st.exitval.fetch("arch"))
      when "LearnMemory"
        mem_gib = st.exitval.fetch("mem_gib")
        vm_host.update(total_mem_gib: mem_gib)
      when "LearnCores"
        kwargs = {
          total_sockets: st.exitval.fetch("total_sockets"),
          total_nodes: st.exitval.fetch("total_nodes"),
          total_dies: st.exitval.fetch("total_dies"),
          total_cores: st.exitval.fetch("total_cores"),
          total_cpus: st.exitval.fetch("total_cpus")
        }

        vm_host.update(**kwargs)
      when "LearnStorage"
        kwargs = {
          total_storage_gib: st.exitval.fetch("total_storage_gib"),
          available_storage_gib: st.exitval.fetch("available_storage_gib")
        }

        vm_host.update(**kwargs)
      end
    end

    if leaf?
      hop_setup_hugepages
    end
    donate
  end

  label def setup_hugepages
    bud Prog::SetupHugepages
    hop_wait_setup_hugepages
  end

  label def wait_setup_hugepages
    reap
    hop_setup_spdk if leaf?
    donate
  end

  label def setup_spdk
    bud(Prog::Storage::SetupSpdk,
      {
        "version" => frame["spdk_version"],
        "start_service" => false,
        "allocation_weight" => 100
      })
    hop_wait_setup_spdk
  end

  label def wait_setup_spdk
    reap
    if leaf?
      hop_prep_reboot
    end
    donate
  end

  label def prep_reboot
    boot_id = get_boot_id
    vm_host.update(last_boot_id: boot_id)

    vm_host.vms.each { |vm|
      vm.update(display_state: "rebooting")
    }

    decr_reboot

    hop_reboot
  end

  label def reboot
    begin
      q_last_boot_id = vm_host.last_boot_id.shellescape
      new_boot_id = sshable.cmd("sudo host/bin/reboot-host #{q_last_boot_id}").strip
    rescue Net::SSH::Disconnect, Net::SSH::ConnectionTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, IOError
      nap 30
    end

    # If we didn't get a valid new boot id, nap. This can happen if reboot-host
    # issues a reboot and returns without closing the ssh connection.
    nap 30 if new_boot_id.length == 0

    vm_host.update(last_boot_id: new_boot_id)
    hop_verify_spdk
  end

  label def verify_spdk
    q_version = frame["spdk_version"].shellescape
    sshable.cmd("sudo host/bin/setup-spdk verify #{q_version}")

    hop_verify_hugepages
  end

  label def verify_hugepages
    host_meminfo = sshable.cmd("cat /proc/meminfo")
    fail "Couldn't set hugepage size to 1G" unless host_meminfo.match?(/^Hugepagesize:\s+1048576 kB$/)

    total_hugepages_match = host_meminfo.match(/^HugePages_Total:\s+(\d+)$/)
    fail "Couldn't extract total hugepage count" unless total_hugepages_match

    free_hugepages_match = host_meminfo.match(/^HugePages_Free:\s+(\d+)$/)
    fail "Couldn't extract free hugepage count" unless free_hugepages_match

    total_hugepages = Integer(total_hugepages_match.captures.first)
    free_hugepages = Integer(free_hugepages_match.captures.first)

    total_vm_mem_gib = vm_host.vms.sum { |vm| vm.mem_gib }
    fail "Not enough hugepages for VMs" unless free_hugepages >= total_vm_mem_gib

    vm_host.update(
      total_hugepages_1g: total_hugepages,
      used_hugepages_1g: total_hugepages - free_hugepages + total_vm_mem_gib
    )

    hop_start_vms
  end

  label def start_vms
    vm_host.vms.each { |vm|
      vm.incr_start_after_host_reboot
    }

    vm_host.update(allocation_state: "accepting")

    hop_wait
  end

  label def wait
    when_reboot_set? do
      hop_prep_reboot
    end

    nap 30
  end

  label def destroy
    decr_destroy

    unless vm_host.allocation_state == "draining"
      vm_host.update(allocation_state: "draining")
      nap 5
    end

    unless vm_host.vms.empty?
      Clog.emit("Cannot destroy the vm host with active virtual machines, first clean them up") { {vm_host: vm_host.values} }
      nap 15
    end

    vm_host.destroy
    sshable.destroy

    pop "vm host deleted"
  end

  def get_boot_id
    sshable.cmd("cat /proc/sys/kernel/random/boot_id").strip
  end
end
