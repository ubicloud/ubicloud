# frozen_string_literal: true

class Prog::Test::Vm < Prog::Base
  subject_is :sshable, :vm

  label def start
    hop_verify_dd
  end

  label def verify_dd
    # Verifies basic block device health
    # See https://github.com/ubicloud/ubicloud/issues/276
    sshable.cmd("dd if=/dev/random of=~/1.txt bs=512 count=1000000")
    sshable.cmd("sync ~/1.txt")
    size_info = sshable.cmd("ls -s ~/1.txt").split

    unless size_info[0].to_i.between?(500000, 500100)
      fail "unexpected size after dd"
    end

    hop_install_packages
  end

  label def install_packages
    sshable.cmd("sudo apt update")
    sshable.cmd("sudo apt install -y build-essential")

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

  def vms_in_same_project
    vm.projects.first.vms_dataset.all.filter { |x|
      x.id != vm.id
    }
  end

  def vms_with_same_subnet
    my_subnet = vm.private_subnets.first.id
    vms_in_same_project.filter { |x|
      x.private_subnets.first.id == my_subnet
    }
  end

  def vms_with_different_subnet
    my_subnet = vm.private_subnets.first.id
    vms_in_same_project.filter { |x|
      x.private_subnets.first.id != my_subnet
    }
  end
end
