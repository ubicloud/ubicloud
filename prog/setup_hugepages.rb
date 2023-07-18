# frozen_string_literal: true

class Prog::SetupHugepages < Prog::Base
  subject_is :sshable, :vm_host

  def start
    hugepage_size = "1G"
    # put away 1 core of overhead for host, and reserve 1G for SPDK
    hugepage_cnt = 1 + (vm_host.total_mem_gib * (vm_host.total_cores - 1)) / vm_host.total_cores
    sshable.cmd("sudo sed -i '/^GRUB_CMDLINE_LINUX=\"/ s/\"$/ hugetlb_free_vmemmap=on default_hugepagesz=#{hugepage_size} hugepagesz=#{hugepage_size} hugepages=#{hugepage_cnt}&/' /etc/default/grub")
    sshable.cmd("sudo update-grub")
    begin
      sshable.cmd("sudo reboot")
    rescue
    end
    hop :wait_reboot
  end

  def wait_reboot
    begin
      sshable.cmd("echo 1")
    rescue
      nap 15
    end

    hop :check_hugepages
  end

  def check_hugepages
    host_meminfo = sshable.cmd("cat /proc/meminfo")
    fail "Couldn't set hugepage size to 1G" unless host_meminfo.match?(/^Hugepagesize:\s+1048576 kB$/)

    total_hugepages_match = host_meminfo.match(/^HugePages_Total:\s+(\d+)$/)
    fail "Couldn't extract total hugepage count" unless total_hugepages_match

    free_hugepages_match = host_meminfo.match(/^HugePages_Free:\s+(\d+)$/)
    fail "Couldn't extract free hugepage count" unless free_hugepages_match

    total_hugepages = Integer(total_hugepages_match.captures.first)
    free_hugepages = Integer(free_hugepages_match.captures.first)

    vm_host.update(
      total_hugepages_1g: total_hugepages,
      used_hugepages_1g: total_hugepages - free_hugepages
    )

    pop "hugepages installed"
  end
end
