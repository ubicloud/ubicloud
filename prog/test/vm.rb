# frozen_string_literal: true

require "json"

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

    hop_storage_persistence
  end

  label def storage_persistence
    # Verifies that data written to storage volumes persists across reboots
    # On first boot, create files with random content and store their sha256 sums
    # On subsequent boots, verify that the files still exist and their content matches
    num_files = 5
    first_boot = frame.fetch("first_boot", true)
    if first_boot
      sshable.cmd("mkdir ~/persistence_test")
      (1..num_files).each do |_|
        sha256 = sshable.cmd("head -c 1M /dev/urandom | tee /tmp/persistence-test | sha256sum | awk '{print $1}'").strip
        sshable.cmd("mv /tmp/persistence-test :file", file: File.join("/home/ubi/persistence_test", sha256))
      end
    else
      files = sshable.cmd("ls ~/persistence_test").split
      fail_test "persistence test: unexpected number of files" if files.size != num_files

      files.each do |file|
        sha256 = sshable.cmd("sha256sum :file | awk '{print $1}'", file: File.join("/home/ubi/persistence_test", file)).strip
        fail_test "persistence test: file content mismatch" unless sha256 == file
      end
    end

    hop_install_packages
  end

  label def install_packages
    if /ubuntu|debian/.match?(vm.boot_image)
      sshable.cmd("sudo apt update")
      sshable.cmd("sudo apt install -y build-essential fio")
    elsif vm.boot_image.start_with?("almalinux")
      sshable.cmd("sudo dnf check-update || [ $? -eq 100 ]")
      sshable.cmd("sudo dnf install -y gcc gcc-c++ make fio")
    else
      fail_test "unexpected boot image: #{vm.boot_image}"
    end

    hop_verify_extra_disks
  end

  def umount_if_mounted(mount_path)
    sshable.cmd("sudo umount :mount_path", mount_path:)
  rescue Sshable::SshError => e
    raise unless e.stderr.include?("not mounted")
  end

  label def verify_extra_disks
    vm.vm_storage_volumes[1..].each_with_index { |volume, disk_index|
      mount_path = "/home/ubi/mnt#{disk_index}"
      sshable.cmd("mkdir -p :mount_path", mount_path:)
      # this might be a retry, so ensure the mount point is not already mounted
      umount_if_mounted(mount_path)
      device_path = volume.device_path
      sshable.cmd("sudo mkfs.ext4 :device_path", device_path:)
      sshable.cmd("sudo mount :device_path :mount_path", device_path:, mount_path:)
      sshable.cmd("sudo chown ubi :mount_path", mount_path:)
      test_file = File.join(mount_path, "1.txt")
      sshable.cmd("dd if=/dev/urandom of=:test_file bs=512 count=10000", test_file:)
      sshable.cmd("sync :test_file", test_file:)
    }

    hop_ping_google
  end

  label def ping_google
    sshable.cmd("ping -c 2 google.com")
    hop_verify_io_rates
  end

  def get_read_bw_bytes
    fio_read_cmd = <<~CMD
      sudo fio --filename=./f --size=100M --direct=1 --rw=randread --bs=1M --ioengine=libaio \\
            --iodepth=256 --runtime=4 --numjobs=1 --time_based --group_reporting \\
            --name=test-job --eta-newline=1 --output-format=json
    CMD

    sshable.cmd_json(fio_read_cmd).dig("jobs", 0, "read", "bw_bytes")
  end

  def get_write_bw_bytes
    fio_write_cmd = <<~CMD
      sudo fio --filename=./f --size=100M --direct=1 --rw=randwrite --bs=1M --ioengine=libaio \\
            --iodepth=256 --runtime=4 --numjobs=1 --time_based --group_reporting \\
            --name=test-job --eta-newline=1 --output-format=json
    CMD

    sshable.cmd_json(fio_write_cmd).dig("jobs", 0, "write", "bw_bytes")
  end

  label def verify_io_rates
    vol = vm.vm_storage_volumes.first
    hop_ping_vms_in_subnet if vol.max_read_mbytes_per_sec.nil?

    # Verify that the max_read_mbytes_per_sec is working
    read_bw_bytes = get_read_bw_bytes
    fail_test "exceeded read bw limit: #{read_bw_bytes}" if read_bw_bytes > vol.max_read_mbytes_per_sec * 1.2 * 1024 * 1024

    # Verify that the max_write_mbytes_per_sec is working
    write_bw_bytes = get_write_bw_bytes
    fail_test "exceeded write bw limit: #{write_bw_bytes}" if write_bw_bytes > vol.max_write_mbytes_per_sec * 1.2 * 1024 * 1024

    hop_ping_vms_in_subnet
  end

  label def ping_vms_in_subnet
    vms_with_same_subnet.each { |x|
      # test public IP reachability
      check_reachable(x.ip4)
      check_reachable(x.ip6) if x.ip6

      # test private IP reachability
      nic = x.nics.first
      private_ip4 = nic.private_ipv4.network.to_s
      check_reachable(private_ip4)

      # Private IPv6 (ULA) only works on metal (IPsec tunnels)
      if vm.location.provider == "metal"
        private_ip6 = nic.private_ipv6.nth(2).to_s
        check_reachable(private_ip6)
      end
    }

    hop_ping_vms_not_in_subnet
  end

  label def ping_vms_not_in_subnet
    vms_with_different_subnet.each { |x|
      # public IPs should be reachable
      check_reachable(x.ip4)
      check_reachable(x.ip6) if x.ip6

      # private IPv4 shouldn't be reachable across subnets
      nic = x.nics.first
      private_ip4 = nic.private_ipv4.network.to_s

      begin
        check_reachable(private_ip4)
      rescue Sshable::SshError
      else
        raise "Unexpected successful connection to private ip4 of a vm in different subnet"
      end

      # Private IPv6 (ULA) isolation only testable on metal (IPsec tunnels)
      if vm.location.provider == "metal"
        private_ip6 = nic.private_ipv6.nth(2).to_s
        begin
          check_reachable(private_ip6)
        rescue Sshable::SshError
        else
          raise "Unexpected successful connection to private ip6 of a vm in different subnet"
        end
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

  def check_reachable(ip)
    if vm.location.provider == "metal"
      sshable.cmd("ping -c 2 :ip", ip:)
    else
      # Cloud providers may not allow ICMP; use TCP connect to port 22
      sshable.cmd("nc -zw5 :ip 22", ip:)
    end
  end

  def vms_in_same_project
    vm.project.vms.filter { it.id != vm.id }
  end

  def vms_with_same_subnet
    vms_in_same_project.filter { it.private_subnets.first.id == vm.private_subnets.first.id }
  end

  def vms_with_different_subnet
    vms_in_same_project.filter { it.private_subnets.first.id != vm.private_subnets.first.id }
  end
end
