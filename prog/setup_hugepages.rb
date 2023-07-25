# frozen_string_literal: true

class Prog::SetupHugepages < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    hugepage_size = "1G"
    # put away 1 core of overhead for host, and reserve 1G for SPDK
    hugepage_cnt = 1 + (vm_host.total_mem_gib * (vm_host.total_cores - 1)) / vm_host.total_cores
    sshable.cmd("sudo sed -i '/^GRUB_CMDLINE_LINUX=\"/ s/\"$/ hugetlb_free_vmemmap=on default_hugepagesz=#{hugepage_size} hugepagesz=#{hugepage_size} hugepages=#{hugepage_cnt}&/' /etc/default/grub")
    sshable.cmd("sudo update-grub")

    pop "hugepages installed"
  end
end
