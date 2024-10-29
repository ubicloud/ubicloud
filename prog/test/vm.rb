# frozen_string_literal: true

class Prog::Test::Vm < Prog::Test::Base
  subject_is :vm, :sshable

  label def start
    hop_verify_dd
  end

  label def verify_dd
    # Verifies basic block device health
    # See https://github.com/ubicloud/ubicloud/issues/276
    sshable.cmd("dd if=/dev/urandom of=~/1.txt bs=512 count=1000000")
    sshable.cmd("sync ~/1.txt")
    size_info = sshable.cmd("ls -s ~/1.txt").split

    unless size_info[0].to_i.between?(500000, 500100)
      fail_test "unexpected size after dd"
    end

    hop_install_packages
  end

  label def install_packages
    if /ubuntu|debian/.match?(vm.boot_image)
      sshable.cmd("sudo apt update")
      sshable.cmd("sudo apt install -y build-essential")
    elsif vm.boot_image.start_with?("almalinux")
      sshable.cmd("sudo dnf check-update || [ $? -eq 100 ]")
      sshable.cmd("sudo dnf install -y gcc gcc-c++ make")
    else
      fail_test "unexpected boot image: #{vm.boot_image}"
    end

    hop_verify_extra_disks
  end

  label def verify_extra_disks
    vm.vm_storage_volumes[1..].each_with_index { |volume, disk_index|
      mount_path = "/home/ubi/mnt#{disk_index}"
      sshable.cmd("mkdir -p #{mount_path}")
      sshable.cmd("sudo mkfs.ext4 #{volume.device_path.shellescape}")
      sshable.cmd("sudo mount #{volume.device_path.shellescape} #{mount_path}")
      sshable.cmd("sudo chown ubi #{mount_path}")
      sshable.cmd("dd if=/dev/urandom of=#{mount_path}/1.txt bs=512 count=10000")
      sshable.cmd("sync #{mount_path}/1.txt")
    }

    hop_ping_google
  end

  label def ping_google
    sshable.cmd("ping -c 2 google.com")
    hop_ping_vms_in_subnet
  end

  label def ping_vms_in_subnet
    vms_with_same_subnet.each { |x|
      # ping public IPs
      sshable.cmd("ping -c 2 #{x.ephemeral_net4}")
      sshable.cmd("ping -c 2 #{x.ephemeral_net6.nth(2)}")

      # ping private IPs
      nic = x.nics.first
      private_ip6 = nic.private_ipv6.nth(2).to_s
      private_ip4 = nic.private_ipv4.network.to_s
      sshable.cmd("ping -c 2 #{private_ip6}")
      sshable.cmd("ping -c 2 #{private_ip4}")
    }

    hop_ping_vms_not_in_subnet
  end

  label def ping_vms_not_in_subnet
    vms_with_different_subnet.each { |x|
      # ping public IPs should work
      sshable.cmd("ping -c 2 #{x.ephemeral_net4}")
      sshable.cmd("ping -c 2 #{x.ephemeral_net6.nth(2)}")

      # ping private IPs shouldn't work
      nic = x.nics.first
      private_ip6 = nic.private_ipv6.nth(2).to_s
      private_ip4 = nic.private_ipv4.network.to_s

      begin
        sshable.cmd("ping -c 2 #{private_ip6}")
      rescue Sshable::SshError
      else
        raise "Unexpected successful ping to private ip6 of a vm in different subnet"
      end

      begin
        sshable.cmd("ping -c 2 #{private_ip4}")
      rescue Sshable::SshError
      else
        raise "Unexpected successful ping to private ip4 of a vm in different subnet"
      end
    }

    hop_finish
  end

  label def finish
    pop "Verified VM!"
  end

  label def failed
    nap 15
  end

  def vms_in_same_project
    vm.projects.first.vms.filter { _1.id != vm.id }
  end

  def vms_with_same_subnet
    vms_in_same_project.filter { _1.private_subnets.first.id == vm.private_subnets.first.id }
  end

  def vms_with_different_subnet
    vms_in_same_project.filter { _1.private_subnets.first.id != vm.private_subnets.first.id }
  end
end
