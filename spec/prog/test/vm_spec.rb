# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Test::Vm do
  subject(:vm_test) {
    described_class.new(Strand.create(prog: "Test::Vm", label: "start", stack: [{"subject_id" => vm.id}]))
  }

  let(:project) { Project.create(name: "default") }
  let(:strand) { vm_test.strand }
  let(:sshable) { vm_test.sshable }
  let(:vm_host) { create_vm_host }
  let(:subnet) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps1", location_id: Location::HETZNER_FSN1_ID).subject
  }

  let(:vm) {
    vm = create_vm(project_id: project.id, vm_host_id: vm_host.id, name: "test-vm-1",
      ephemeral_net6: "2001:db8:85a1::/64")
    Sshable.create_with_id(vm)
    Strand.create(id: vm.id, prog: "Vm::Nexus", label: "wait")
    Nic.create(private_subnet_id: subnet.id, vm_id: vm.id, name: "nic-1",
      private_ipv4: "192.168.0.1/32", private_ipv6: "fd01:db8:85a1::/64",
      mac: "00:00:00:00:00:01", state: "active")
    sd = StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", total_storage_gib: 100, available_storage_gib: 100, unix_device_list: ["sda"])
    VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 20, disk_index: 0, use_bdev_ubi: false, storage_device_id: sd.id)
    VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 20, disk_index: 1, use_bdev_ubi: false, storage_device_id: sd.id)
    vm
  }

  def create_vm_with_nic(subnet:, name:, ephemeral_net6:, nic_name:, private_ipv4:, private_ipv6:, mac:, ipv4:)
    vm = create_vm(project_id: project.id, vm_host_id: vm_host.id, name:,
      ephemeral_net6:)
    Nic.create(private_subnet_id: subnet.id, vm_id: vm.id, name: nic_name,
      private_ipv4:, private_ipv6:,
      mac:, state: "active")
    add_ipv4_to_vm(vm, ipv4)
    vm
  end

  describe "#start" do
    it "hops to verify_dd" do
      expect { vm_test.start }.to hop("verify_dd")
    end
  end

  describe "#verify_dd" do
    it "verifies dd" do
      expect(sshable).to receive(:_cmd).with("dd if=/dev/urandom of=~/1.txt bs=512 count=1000000")
      expect(sshable).to receive(:_cmd).with("sync ~/1.txt")
      expect(sshable).to receive(:_cmd).with("ls -s ~/1.txt").and_return "500004 /home/xyz/1.txt"
      expect { vm_test.verify_dd }.to hop("storage_persistence")
    end

    it "fails to verify if size is not in expected range" do
      expect(sshable).to receive(:_cmd).with("dd if=/dev/urandom of=~/1.txt bs=512 count=1000000")
      expect(sshable).to receive(:_cmd).with("sync ~/1.txt")
      expect(sshable).to receive(:_cmd).with("ls -s ~/1.txt").and_return "300 /home/xyz/1.txt"
      expect { vm_test.verify_dd }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "unexpected size after dd"})
    end
  end

  describe "#storage_persistence" do
    it "creates files on first boot" do
      refresh_frame(vm_test, new_values: {"first_boot" => true})
      expect(sshable).to receive(:_cmd).with("mkdir ~/persistence_test")
      (1..5).each do |i|
        some_sha256 = "sha256_#{i}"
        expect(sshable).to receive(:_cmd).with("head -c 1M /dev/urandom | tee /tmp/persistence-test | sha256sum | awk '{print $1}'").and_return(some_sha256)
        expect(sshable).to receive(:_cmd).with("mv /tmp/persistence-test /home/ubi/persistence_test/#{some_sha256}")
      end
      expect { vm_test.storage_persistence }.to hop("install_packages")
    end

    it "verifies files on subsequent boots" do
      refresh_frame(vm_test, new_values: {"first_boot" => false})
      expect(sshable).to receive(:_cmd).with("ls ~/persistence_test").and_return("sha256_1\nsha256_2\nsha256_3\nsha256_4\nsha256_5\n")
      (1..5).each do |i|
        some_sha256 = "sha256_#{i}"
        expect(sshable).to receive(:_cmd).with("sha256sum /home/ubi/persistence_test/#{some_sha256} | awk '{print $1}'").and_return(some_sha256)
      end
      expect { vm_test.storage_persistence }.to hop("install_packages")
    end

    it "fails if number of files is unexpected" do
      refresh_frame(vm_test, new_values: {"first_boot" => false})
      expect(sshable).to receive(:_cmd).with("ls ~/persistence_test").and_return("sha256_1\nsha256_2\nsha256_3\n")
      expect { vm_test.storage_persistence }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "persistence test: unexpected number of files"})
    end

    it "fails if file content mismatches" do
      refresh_frame(vm_test, new_values: {"first_boot" => false})
      expect(sshable).to receive(:_cmd).with("ls ~/persistence_test").and_return("sha256_1\nsha256_2\nsha256_3\nsha256_4\nsha256_5\n")
      expect(sshable).to receive(:_cmd).with("sha256sum /home/ubi/persistence_test/sha256_1 | awk '{print $1}'").and_return("different_sha256")
      expect { vm_test.storage_persistence }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "persistence test: file content mismatch"})
    end
  end

  describe "#install_packages" do
    it "installs packages for ubuntu images and hops to next step" do
      vm.update(boot_image: "ubuntu-jammy")
      expect(sshable).to receive(:_cmd).with("sudo apt update")
      expect(sshable).to receive(:_cmd).with("sudo apt install -y build-essential fio")
      expect { vm_test.install_packages }.to hop("verify_extra_disks")
    end

    it "installs packages for debian images and hops to next step" do
      vm.update(boot_image: "debian-12")
      expect(sshable).to receive(:_cmd).with("sudo apt update")
      expect(sshable).to receive(:_cmd).with("sudo apt install -y build-essential fio")
      expect { vm_test.install_packages }.to hop("verify_extra_disks")
    end

    it "installs packages for almalinux images and hops to next step" do
      vm.update(boot_image: "almalinux-9")
      expect(sshable).to receive(:_cmd).with("sudo dnf check-update || [ $? -eq 100 ]")
      expect(sshable).to receive(:_cmd).with("sudo dnf install -y gcc gcc-c++ make fio")
      expect { vm_test.install_packages }.to hop("verify_extra_disks")
    end

    it "fails to install packages if the vm has unexpected boot image" do
      vm.update(boot_image: "windows")
      expect { vm_test.install_packages }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "unexpected boot image: windows"})
    end
  end

  describe "#umount_if_mounted" do
    it "unmounts if mounted" do
      mount_path = "/home/ubi/mnt0"
      expect(sshable).to receive(:_cmd).with("sudo umount #{mount_path}")
      expect { vm_test.umount_if_mounted(mount_path) }.not_to raise_error
    end

    it "does not raise error if not mounted" do
      mount_path = "/home/ubi/mnt0"
      expect(sshable).to receive(:_cmd).with("sudo umount #{mount_path}").and_raise(Sshable::SshError.new("sudo umount #{mount_path}", "", "umount: #{mount_path}: not mounted.\n", nil, nil))
      expect { vm_test.umount_if_mounted(mount_path) }.not_to raise_error
    end

    it "raises error for unexpected ssh error" do
      mount_path = "/home/ubi/mnt0"
      expect(sshable).to receive(:_cmd).with("sudo umount #{mount_path}").and_raise(Sshable::SshError.new("unexpected error", "", "", nil, nil))
      expect { vm_test.umount_if_mounted(mount_path) }.to raise_error Sshable::SshError, /unexpected error/
    end
  end

  describe "#verify_extra_disks" do
    it "verifies extra disks" do
      vol = vm_test.vm.vm_storage_volumes.find { it.disk_index == 1 }
      disk_path = vol.device_path
      mount_path = "/home/ubi/mnt0"
      expect(vm_test).to receive(:umount_if_mounted).with(mount_path)
      expect(sshable).to receive(:_cmd).with("mkdir -p #{mount_path}")
      expect(sshable).to receive(:_cmd).with("sudo mkfs.ext4 #{disk_path}")
      expect(sshable).to receive(:_cmd).with("sudo mount #{disk_path} #{mount_path}")
      expect(sshable).to receive(:_cmd).with("sudo chown ubi #{mount_path}")
      expect(sshable).to receive(:_cmd).with("dd if=/dev/urandom of=#{mount_path}/1.txt bs=512 count=10000")
      expect(sshable).to receive(:_cmd).with("sync #{mount_path}/1.txt")
      expect { vm_test.verify_extra_disks }.to hop("verify_vm_stats")
    end
  end

  describe "#verify_vm_stats" do
    let(:valid_vm_stats_output) {
      {
        "main_pid" => "1234",
        "vcpus" => 8,
        "active_age_ms" => 60000,
        "cpu_stats" => {"user_time_ms" => 104780, "system_time_ms" => 4910, "total_time_ms" => 109690},
      }
    }

    let(:valid_disk_stats_output) {
      {
        "main_pid" => "3162",
        "memory_peak_bytes" => 40050688,
        "memory_swap_peak_bytes" => 0,
        "active_age_ms" => 123000,
        "num_queues" => 4,
        "queue_size" => 256,
        "size_gib" => 100,
        "vhost_block_backend_version" => "1.0",
        "cpu_stats" => {"user_time_ms" => 104430, "system_time_ms" => 4900, "total_time_ms" => 109330},
        "io_stats" => {"read_bytes" => 111111, "write_bytes" => 222222},
      }
    }

    it "verifies vm stats and hops to verify_storage_rpc" do
      vm_stats_output = {
        "disk_0" => valid_disk_stats_output,
        "disk_1" => valid_disk_stats_output,
        "vm" => valid_vm_stats_output,
      }
      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/vm-stats #{vm_test.vm.inhost_name}").and_return(vm_stats_output.to_json)
      expect { vm_test.verify_vm_stats }.to hop("verify_storage_rpc")
    end

    it "fails if top level key vm is missing in vm-stats output" do
      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/vm-stats #{vm_test.vm.inhost_name}").and_return({unexpected_key: "value"}.to_json)
      expect { vm_test.verify_vm_stats }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "missing top-level key 'vm' in vm-stats output"})
    end

    it "fails if disk_1 key is missing in vm-stats output" do
      vm_stats_output = {
        "disk_0" => valid_disk_stats_output,
        "vm" => valid_vm_stats_output,
      }

      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/vm-stats #{vm_test.vm.inhost_name}").and_return(vm_stats_output.to_json)
      expect { vm_test.verify_vm_stats }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "missing expected key 'disk_1' in vm-stats output"})
    end

    it "fails if expected keys are missing in vm stats" do
      vm_stats_output = {
        "disk_0" => valid_disk_stats_output,
        "vm" => {
          "unexpected_key" => "value",
        },
      }

      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/vm-stats #{vm_test.vm.inhost_name}").and_return(vm_stats_output.to_json)
      expect { vm_test.verify_vm_stats }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "missing expected keys in vm stats"})
    end

    it "fails if expected keys are missing in disk_0 stats" do
      vm_stats_output = {
        "disk_0" => {
          "unexpected_key" => "value",
        },
        "vm" => valid_vm_stats_output,
      }
      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("sudo host/bin/vm-stats #{vm_test.vm.inhost_name}").and_return(vm_stats_output.to_json)
      expect { vm_test.verify_vm_stats }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "missing expected keys in disk_0 stats"})
    end
  end

  describe "#verify_storage_rpc" do
    it "hops to stop_semaphore when version matches" do
      expected_version = Config.vhost_block_backend_version.delete_prefix("v")
      request = {"command" => "version"}.to_json
      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/#{vm_test.vm.inhost_name}/0/rpc.sock -q 2 -w 2 | head -n 1", stdin: request).and_return({"version" => expected_version}.to_json)
      expect { vm_test.verify_storage_rpc }.to hop("stop_semaphore")
    end

    it "fails if unable to get vhost-block-backend version using RPC" do
      request = {"command" => "version"}.to_json
      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("sudo nc -U /var/storage/#{vm_test.vm.inhost_name}/0/rpc.sock -q 2 -w 2 | head -n 1", stdin: request).and_return({"error" => "some error"}.to_json)
      expect { vm_test.verify_storage_rpc }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "Failed to get vhost-block-backend version for VM #{vm_test.vm.ubid} using RPC"})
    end
  end

  describe "#ping_google" do
    it "pings google and hops to next step" do
      expect(sshable).to receive(:_cmd).with("ping -c 2 google.com")
      expect { vm_test.ping_google }.to hop("verify_io_rates")
    end
  end

  describe "#get_read_bw_bytes" do
    it "returns read bw in mbytes" do
      output = {
        "jobs" => [
          {
            "read" => {"bw_bytes" => 1048576},
          },
        ],
      }
      expect(sshable).to receive(:_cmd).with(/sudo fio.*/).and_return output.to_json
      expect(vm_test.get_read_bw_bytes).to eq 1048576
    end
  end

  describe "#get_write_bw_bytes" do
    it "returns write bw in bytes" do
      output = {
        "jobs" => [
          {
            "write" => {"bw_bytes" => 1048576},
          },
        ],
      }
      expect(sshable).to receive(:_cmd).with(/sudo fio.*/).and_return output.to_json
      expect(vm_test.get_write_bw_bytes).to eq 1048576
    end
  end

  describe "#verify_io_rates" do
    before {
      vm_test.vm.vm_storage_volumes.first.update(max_read_mbytes_per_sec: 200, max_write_mbytes_per_sec: 150)
    }

    it "skips if io rates are not set" do
      vm_test.vm.vm_storage_volumes.first.update(max_read_mbytes_per_sec: nil, max_write_mbytes_per_sec: nil)
      expect { vm_test.verify_io_rates }.to hop("ping_vms_in_subnet")
    end

    it "verifies io rates" do
      expect(vm_test).to receive(:get_read_bw_bytes).and_return 180 * 1024 * 1024
      expect(vm_test).to receive(:get_write_bw_bytes).and_return 150 * 1024 * 1024
      expect { vm_test.verify_io_rates }.to hop("ping_vms_in_subnet")
    end

    it "fails if read mbytes per sec exceeds the limit" do
      expect(vm_test).to receive(:get_read_bw_bytes).and_return 280 * 1024 * 1024
      expect { vm_test.verify_io_rates }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "exceeded read bw limit: 293601280"})
    end

    it "fails if write mbytes per sec exceeds the limit" do
      expect(vm_test).to receive(:get_read_bw_bytes).and_return 200 * 1024 * 1024
      expect(vm_test).to receive(:get_write_bw_bytes).and_return 320 * 1024 * 1024
      expect { vm_test.verify_io_rates }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "exceeded write bw limit: 335544320"})
    end
  end

  describe "#ping_vms_in_subnet" do
    it "pings vm in same subnet and hops to next step" do
      other_vm = create_vm_with_nic(subnet:, name: "test-vm-2",
        ephemeral_net6: "2001:db8:85a2::/64", nic_name: "nic-2",
        private_ipv4: "192.168.0.2/32", private_ipv6: "fd01:db8:85a2::/64",
        mac: "00:00:00:00:00:02", ipv4: "1.1.1.2")
      nic = other_vm.nics.first
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{other_vm.ip4}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{nic.private_ipv4.network}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{other_vm.ip6}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{nic.private_ipv6.nth(2)}")
      expect { vm_test.ping_vms_in_subnet }.to hop("ping_vms_not_in_subnet")
    end
  end

  describe "#ping_vms_not_in_subnet" do
    let(:other_subnet) {
      Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps2", location_id: Location::HETZNER_FSN1_ID).subject
    }
    let(:other_vm) {
      create_vm_with_nic(subnet: other_subnet, name: "test-vm-3",
        ephemeral_net6: "2001:db8:85a3::/64", nic_name: "nic-3",
        private_ipv4: "192.168.0.3/32", private_ipv6: "fd01:db8:85a3::/64",
        mac: "00:00:00:00:00:03", ipv4: "1.1.2.3")
    }

    it "fails to ping private interfaces of vms not in the same subnet and hops to next step" do
      nic = other_vm.nics.first
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{other_vm.ip4}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{nic.private_ipv4.network}").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{other_vm.ip6}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{nic.private_ipv6.nth(2)}").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect { vm_test.ping_vms_not_in_subnet }.to hop("finish")
    end

    it "raises error if pinging private ipv4 of vms in other subnets succeed" do
      nic = other_vm.nics.first
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{other_vm.ip4}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{nic.private_ipv4.network}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{other_vm.ip6}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{nic.private_ipv6.nth(2)}").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect { vm_test.ping_vms_not_in_subnet }.to raise_error RuntimeError, "Unexpected successful ping to private ip4 of a vm in different subnet"
    end

    it "raises error if pinging private ipv6 of vms in other subnets succeed" do
      nic = other_vm.nics.first
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{other_vm.ip4}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{other_vm.ip6}")
      expect(sshable).to receive(:_cmd).with("ping -c 2 #{nic.private_ipv6.nth(2)}")
      expect { vm_test.ping_vms_not_in_subnet }.to raise_error RuntimeError, "Unexpected successful ping to private ip6 of a vm in different subnet"
    end
  end

  describe "#stop_semaphore" do
    it "increments stop semaphore and hops" do
      expect { vm_test.stop_semaphore }.to hop("check_stopped_by_stop_semaphore")
      expect(vm_test.vm.stop_set?).to be true
    end
  end

  describe "#check_stopped_by_stop_semaphore" do
    it "naps if strand not at expected label" do
      expect { vm_test.check_stopped_by_stop_semaphore }.to nap(5)
    end

    it "naps if VM is up" do
      vm_test.vm.strand.update(label: "stopped")
      expect(sshable).to receive(:_cmd).with("true").and_return("")
      expect { vm_test.check_stopped_by_stop_semaphore }.to nap(5)
    end

    it "hops if VM is down" do
      vm_test.vm.strand.update(label: "stopped")
      expect(vm_test.sshable).to receive(:_cmd).with("true").and_raise(Errno::ECONNREFUSED)
      expect { vm_test.check_stopped_by_stop_semaphore }.to hop("start_semaphore_after_stop")
    end
  end

  describe "#start_semaphore_after_stop" do
    it "increments semaphore and hops" do
      expect { vm_test.start_semaphore_after_stop }.to hop("check_started_by_start_semaphore")
      expect(vm_test.vm.start_set?).to be true
    end
  end

  describe "#check_started_by_start_semaphore" do
    it "naps if strand not at expected label" do
      vm_test.vm.strand.update(label: "stopped")
      expect { vm_test.check_started_by_start_semaphore }.to nap(5)
    end

    it "naps if VM is up" do
      expect(vm_test.sshable).to receive(:_cmd).with("true").and_raise(Errno::ECONNREFUSED)
      expect { vm_test.check_started_by_start_semaphore }.to nap(5)
    end

    it "hops if VM is up" do
      expect(vm_test.sshable).to receive(:_cmd).with("true").and_return("")
      expect { vm_test.check_started_by_start_semaphore }.to hop("shutdown_command")
    end
  end

  describe "#shutdown_command" do
    it "shuts down VM via SSH and hops" do
      expect(vm_test.sshable).to receive(:_cmd).with("sudo shutdown now").and_return("")
      expect { vm_test.shutdown_command }.to hop("check_stopped_by_shutdown_command")
    end

    it "handles Errno::ECONNRESET while executing command" do
      expect(vm_test.sshable).to receive(:_cmd).with("sudo shutdown now").and_raise(Errno::ECONNRESET)
      expect { vm_test.shutdown_command }.to hop("check_stopped_by_shutdown_command")
    end
  end

  describe "#check_stopped_by_shutdown_command" do
    it "naps if strand not at expected label" do
      expect { vm_test.check_stopped_by_shutdown_command }.to nap(5)
    end

    it "naps if VM is up" do
      vm_test.vm.strand.update(label: "stopped")
      expect(vm_test.sshable).to receive(:_cmd).with("true").and_return("")
      expect { vm_test.check_stopped_by_shutdown_command }.to nap(5)
    end

    it "hops if VM is down" do
      vm_test.vm.strand.update(label: "stopped")
      expect(vm_test.sshable).to receive(:_cmd).with("true").and_raise(Errno::ECONNREFUSED)
      expect { vm_test.check_stopped_by_shutdown_command }.to hop("verify_systemd_unit_status_after_shutdown")
    end
  end

  describe "#verify_systemd_unit_status_after_shutdown" do
    it "verifies systemd unit status and hops" do
      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("systemctl is-active #{vm_test.vm.inhost_name}").and_raise(Sshable::SshError.new("systemctl is-active #{vm_test.vm.inhost_name}", "inactive\n", "", nil, nil))
      expect { vm_test.verify_systemd_unit_status_after_shutdown }.to hop("start_semaphore_after_shutdown")
    end

    it "naps if VM is still active" do
      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("systemctl is-active #{vm_test.vm.inhost_name}").and_return("active\n")
      expect { vm_test.verify_systemd_unit_status_after_shutdown }.to nap(5)
    end

    it "fails if systemd unit status is unexpected" do
      expect(vm_test.vm.vm_host.sshable).to receive(:_cmd).with("systemctl is-active #{vm_test.vm.inhost_name}").and_return("unknown\n")
      expect { vm_test.verify_systemd_unit_status_after_shutdown }.to hop("failed")
      expect(vm_test.strand.exitval).to eq({msg: "VM should be inactive after shutdown command, but is unknown"})
    end
  end

  describe "#start_semaphore_after_shutdown" do
    it "increments semaphore and hops" do
      expect { vm_test.start_semaphore_after_shutdown }.to hop("check_started_after_shutdown")
      expect(vm_test.vm.start_set?).to be true
    end
  end

  describe "#check_started_after_shutdown" do
    it "naps if strand not at expected label" do
      vm_test.vm.strand.update(label: "stopped")
      expect { vm_test.check_started_after_shutdown }.to nap(5)
    end

    it "naps if VM is up" do
      expect(vm_test.sshable).to receive(:_cmd).with("true").and_raise(Errno::ECONNREFUSED)
      expect { vm_test.check_started_after_shutdown }.to nap(5)
    end

    it "hops if VM is up" do
      expect(vm_test.sshable).to receive(:_cmd).with("true").and_return("")
      expect { vm_test.check_started_after_shutdown }.to hop("ping_google")
    end
  end

  describe "#finish" do
    it "exits" do
      expect { vm_test.finish }.to exit({"msg" => "Verified VM!"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { vm_test.failed }.to nap(15)
    end
  end
end
