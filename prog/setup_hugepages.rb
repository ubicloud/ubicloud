# frozen_string_literal: true

class Prog::SetupHugepages < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    hugepage_size = "1G"

    # Reserve 5G of overhead for the host. SPDK will use 2 of the hugepages +
    # upto about 1G of the 5G as not all SPDK allocations are from hugepages.
    # On production servers we have observed total memory to be up to ~1/43
    # lower than the reported physical memory. We therefore use 42/43 as a
    # safety ratio to avoid overcommitting memory for hugepages.
    hugepage_cnt = vm_host.total_mem_gib * 42 / 43 - 5

    # Platforms with large kernel or driver preallocations keep less usable
    # memory than physical memory implies; clamp against measured
    # MemAvailable so the reservation cannot starve the host OS.
    host_meminfo = sshable.cmd("cat /proc/meminfo")
    available_memory_match = host_meminfo.match(/^MemAvailable:\s+(\d+) kB$/)
    fail "Couldn't extract available memory" unless available_memory_match
    available_limit = Integer(available_memory_match.captures.first) / 1048576 - 4
    if available_limit < hugepage_cnt
      Clog.emit("hugepage count clamped to available memory", {hugepage_clamp: {formula_count: hugepage_cnt, clamped_count: available_limit}})
      hugepage_cnt = available_limit
    end

    sshable.cmd("sudo sed -i '/^GRUB_CMDLINE_LINUX=\"/ s/\"$/ hugetlb_free_vmemmap=on default_hugepagesz=':hugepage_size' hugepagesz=':hugepage_size' hugepages=':hugepage_cnt'&/' /etc/default/grub", hugepage_size:, hugepage_cnt:)
    sshable.cmd("sudo update-grub")

    pop "hugepages installed"
  end
end
