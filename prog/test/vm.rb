# frozen_string_literal: true

class Prog::Test::Vm < Prog::Base
  subject_is :vm

  label def start
    hop_verify_dd
  end

  label def verify_dd
    # Verifies basic block device health
    # See https://github.com/ubicloud/ubicloud/issues/276
    size_info = ssh([
      "dd if=/dev/random of=~/1.txt bs=512 count=1000000",
      "sync ~/1.txt",
      "ls -s ~/1.txt"
    ]).split

    unless size_info[0].to_i.between?(500000, 500100)
      fail "unexpected size after dd"
    end

    hop_install_packages
  end

  label def install_packages
    ssh(["sudo apt update",
      "sudo apt install -y build-essential"])

    hop_ping_google
  end

  label def ping_google
    ssh(["ping -c 2 google.com"])
    hop_ping_vms_in_subnet
  end

  label def ping_vms_in_subnet
    vms_with_same_subnet.each { |x|
      # ping public IPs
      ssh(["ping -c 2 #{x.ephemeral_net4}",
        "ping -c 2 #{x.ephemeral_net6.nth(2)}"])

      # ping private IPs
      nic = x.nics.first
      private_ip6 = nic.private_ipv6.nth(2).to_s
      private_ip4 = nic.private_ipv4.network.to_s
      ssh(["ping -c 2 #{private_ip6}",
        "ping -c 2 #{private_ip4}"])
    }

    hop_ping_vms_not_in_subnet
  end

  label def ping_vms_not_in_subnet
    vms_with_different_subnet.each { |x|
      # ping public IPs should work
      ssh(["ping -c 2 #{x.ephemeral_net4}",
        "ping -c 2 #{x.ephemeral_net6.nth(2)}"])

      # ping private IPs shouldn't work
      nic = x.nics.first
      private_ip6 = nic.private_ipv6.nth(2).to_s
      private_ip4 = nic.private_ipv4.network.to_s

      begin
        ssh(["ping -c 2 #{private_ip6}"])
      rescue RuntimeError
      else
        raise "Unexpected successful ping to private ip6 of a vm in different subnet"
      end

      begin
        ssh(["ping -c 2 #{private_ip4}"])
      rescue RuntimeError
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

  # YYY: this is a temporary solution until we make Sshable work with
  # custom usernames.
  def ssh(cmds, private_key)
    ret = nil
    Net::SSH.start(frame["hostname"], "ubi",
      key_data: [private_key],
      verify_host_key: :never,
      number_of_password_prompts: 0) do |ssh|
      cmds.each { |cmd|
        ret = ssh.exec!(cmd)
        fail "Command exited with nonzero status" unless ret.exitstatus.zero?
      }
    end
    ret
  end
end
