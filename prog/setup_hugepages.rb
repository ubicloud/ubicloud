# frozen_string_literal: true

class Prog::SetupHugepages < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    hugepage_size = "1G"

    # Reserve 5G of overhead for the host. SPDK will use 2 of the hugepages +
    # upto about 1G of the 5G as not all SPDK allocations are from hugepages.
    hugepage_cnt = vm_host.total_mem_gib - 5

    sshable.cmd("sudo sed -i '/^GRUB_CMDLINE_LINUX=\"/ s/\"$/ hugetlb_free_vmemmap=on default_hugepagesz=':hugepage_size' hugepagesz=':hugepage_size' hugepages=':hugepage_cnt'&/' /etc/default/grub", hugepage_size:, hugepage_cnt:)
    sshable.cmd("sudo update-grub")

    pop "hugepages installed"
  end
end
