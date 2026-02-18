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
      # ping public IPs
      sshable.cmd("ping -c 2 :ip", ip: x.ip4)
      sshable.cmd("ping -c 2 :ip", ip: x.ip6)

      # ping private IPs
      nic = x.nics.first
      private_ip6 = nic.private_ipv6.nth(2).to_s
      private_ip4 = nic.private_ipv4.network.to_s
      sshable.cmd("ping -c 2 :ip", ip: private_ip6)
      sshable.cmd("ping -c 2 :ip", ip: private_ip4)
    }

    hop_ping_vms_not_in_subnet
  end

  label def ping_vms_not_in_subnet
    vms_with_different_subnet.each { |x|
      # ping public IPs should work
      sshable.cmd("ping -c 2 :ip", ip: x.ip4)
      sshable.cmd("ping -c 2 :ip", ip: x.ip6)

      # ping private IPs shouldn't work
      nic = x.nics.first
      private_ip6 = nic.private_ipv6.nth(2).to_s
      private_ip4 = nic.private_ipv4.network.to_s

      begin
        sshable.cmd("ping -c 2 :ip", ip: private_ip6)
      rescue Sshable::SshError
      else
        raise "Unexpected successful ping to private ip6 of a vm in different subnet"
      end

      begin
        sshable.cmd("ping -c 2 :ip", ip: private_ip4)
      rescue Sshable::SshError
      else
        raise "Unexpected successful ping to private ip4 of a vm in different subnet"
      end
    }

    hop_stop_semaphore
  end

  label def stop_semaphore
    vm.incr_stop
    hop_check_stopped_by_stop_semaphore
  end

  label def check_stopped_by_stop_semaphore
    if vm.strand.label == "stopped" && !up?
      hop_start_semaphore_after_stop
    end

    nap 5
  end

  label def start_semaphore_after_stop
    vm.incr_start
    hop_check_started_by_start_semaphore
  end

  label def check_started_by_start_semaphore
    if vm.strand.label == "wait" && up?
      hop_shutdown_command
    end

    nap 5
  end

  label def shutdown_command
    begin
      sshable.cmd("sudo shutdown now")
    rescue Errno::ECONNRESET, IOError, Net::SSH::Disconnect
      nil
    end

    hop_check_stopped_by_shutdown_command
  end

  label def check_stopped_by_shutdown_command
    if vm.strand.label == "stopped" && !up?
      hop_start_semaphore_after_shutdown
    end

    nap 5
  end

  label def start_semaphore_after_shutdown
    vm.incr_start
    hop_check_started_after_shutdown
  end

  label def check_started_after_shutdown
    if vm.strand.label == "wait" && up?
      hop_finish
    end

    nap 5
  end

  label def finish
    pop "Verified VM!"
  end

  def up?
    sshable.cmd("true")
    true
  rescue Sshable::SshError, *Sshable::SSH_CONNECTION_ERRORS
    false
  end

  label def failed
    nap 15
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
