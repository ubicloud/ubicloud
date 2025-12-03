# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Test::Vm do
  subject(:vm_test) {
    described_class.new(Strand.new(prog: "Test::Vm"))
  }

  let(:sshable) {
    Sshable.new
  }

  before {
    subnet1 = instance_double(PrivateSubnet, id: "subnet1")
    subnet2 = instance_double(PrivateSubnet, id: "subnet2")

    main_storage_volume = instance_double(VmStorageVolume, device_path: "/dev/disk/by-id/disk_0")
    extra_storage_volume = instance_double(VmStorageVolume, device_path: "/dev/disk/by-id/disk_1")

    nic1 = instance_double(Nic,
      private_ipv6: NetAddr::IPv6Net.parse("fd01:0db8:85a1::/64"),
      private_ipv4: NetAddr::IPv4Net.parse("192.168.0.1/32"))
    vm1 = instance_double(Vm, id: "vm1",
      private_subnets: [subnet1],
      ip4: "1.1.1.1",
      ip6: "2001:db8:85a1::2",
      nics: [nic1],
      vm_storage_volumes: [main_storage_volume, extra_storage_volume])

    nic2 = instance_double(Nic,
      private_ipv6: NetAddr::IPv6Net.parse("fd01:0db8:85a2::/64"),
      private_ipv4: NetAddr::IPv4Net.parse("192.168.0.2/32"))
    vm2 = instance_double(Vm, id: "vm2",
      private_subnets: [subnet1],
      ip4: "1.1.1.2",
      ip6: "2001:db8:85a2::2",
      nics: [nic2])

    nic3 = instance_double(Nic,
      private_ipv6: NetAddr::IPv6Net.parse("fd01:0db8:85a3::/64"),
      private_ipv4: NetAddr::IPv4Net.parse("192.168.0.3/32"))
    vm3 = instance_double(Vm, id: "vm3",
      private_subnets: [subnet2],
      ip4: "1.1.1.3",
      ip6: "2001:db8:85a3::2",
      nics: [nic3])

    project = Project.create(name: "default")
    allow(project).to receive(:vms).and_return([vm1, vm2, vm3])
    allow(vm1).to receive(:project).and_return project
    allow(vm_test).to receive_messages(sshable: sshable, vm: vm1)
  }

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
      expect { vm_test.verify_dd }.to hop("install_packages")
    end

    it "fails to verify if size is not in expected range" do
      expect(sshable).to receive(:_cmd).with("dd if=/dev/urandom of=~/1.txt bs=512 count=1000000")
      expect(sshable).to receive(:_cmd).with("sync ~/1.txt")
      expect(sshable).to receive(:_cmd).with("ls -s ~/1.txt").and_return "300 /home/xyz/1.txt"
      expect(vm_test.strand).to receive(:update).with(exitval: {msg: "unexpected size after dd"})
      expect { vm_test.verify_dd }.to hop("failed")
    end
  end

  describe "#install_packages" do
    it "installs packages for ubuntu images and hops to next step" do
      expect(vm_test).to receive(:vm).and_return(instance_double(Vm, boot_image: "ubuntu-jammy")).at_least(:once)
      expect(sshable).to receive(:_cmd).with("sudo apt update")
      expect(sshable).to receive(:_cmd).with("sudo apt install -y build-essential fio")
      expect { vm_test.install_packages }.to hop("verify_extra_disks")
    end

    it "installs packages for debian images and hops to next step" do
      expect(vm_test).to receive(:vm).and_return(instance_double(Vm, boot_image: "debian-12")).at_least(:once)
      expect(sshable).to receive(:_cmd).with("sudo apt update")
      expect(sshable).to receive(:_cmd).with("sudo apt install -y build-essential fio")
      expect { vm_test.install_packages }.to hop("verify_extra_disks")
    end

    it "installs packages for almalinux images and hops to next step" do
      expect(vm_test).to receive(:vm).and_return(instance_double(Vm, boot_image: "almalinux-9")).at_least(:once)
      expect(sshable).to receive(:_cmd).with("sudo dnf check-update || [ $? -eq 100 ]")
      expect(sshable).to receive(:_cmd).with("sudo dnf install -y gcc gcc-c++ make fio")
      expect { vm_test.install_packages }.to hop("verify_extra_disks")
    end

    it "fails to install packages if the vm has unexpected boot image" do
      expect(vm_test).to receive(:vm).and_return(instance_double(Vm, boot_image: "windows")).at_least(:once)
      expect(vm_test.strand).to receive(:update).with(exitval: {msg: "unexpected boot image: windows"})
      expect { vm_test.install_packages }.to hop("failed")
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
      disk_path = "/dev/disk/by-id/disk_1"
      mount_path = "/home/ubi/mnt0"
      expect(vm_test).to receive(:umount_if_mounted).with(mount_path)
      expect(sshable).to receive(:_cmd).with("mkdir -p #{mount_path}")
      expect(sshable).to receive(:_cmd).with("sudo mkfs.ext4 #{disk_path}")
      expect(sshable).to receive(:_cmd).with("sudo mount #{disk_path} #{mount_path}")
      expect(sshable).to receive(:_cmd).with("sudo chown ubi #{mount_path}")
      expect(sshable).to receive(:_cmd).with("dd if=/dev/urandom of=#{mount_path}/1.txt bs=512 count=10000")
      expect(sshable).to receive(:_cmd).with("sync #{mount_path}/1.txt")
      expect { vm_test.verify_extra_disks }.to hop("ping_google")
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
            "read" => {"bw_bytes" => 1048576}
          }
        ]
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
            "write" => {"bw_bytes" => 1048576}
          }
        ]
      }
      expect(sshable).to receive(:_cmd).with(/sudo fio.*/).and_return output.to_json
      expect(vm_test.get_write_bw_bytes).to eq 1048576
    end
  end

  describe "#verify_io_rates" do
    before {
      vol = instance_double(VmStorageVolume, device_path: "/dev/disk/by-id/disk_0",
        max_read_mbytes_per_sec: 200, max_write_mbytes_per_sec: 150)
      allow(vm_test.vm).to receive(:vm_storage_volumes).and_return([vol])
    }

    it "skips if io rates are not set" do
      vol = instance_double(VmStorageVolume, device_path: "/dev/disk/by-id/disk_0",
        max_read_mbytes_per_sec: nil, max_write_mbytes_per_sec: nil)
      allow(vm_test.vm).to receive(:vm_storage_volumes).and_return([vol]).at_least(:once)
      expect { vm_test.verify_io_rates }.to hop("ping_vms_in_subnet")
    end

    it "verifies io rates" do
      expect(vm_test).to receive(:get_read_bw_bytes).and_return 180 * 1024 * 1024
      expect(vm_test).to receive(:get_write_bw_bytes).and_return 150 * 1024 * 1024
      expect { vm_test.verify_io_rates }.to hop("ping_vms_in_subnet")
    end

    it "fails if read mbytes per sec exceeds the limit" do
      expect(vm_test).to receive(:get_read_bw_bytes).and_return 280 * 1024 * 1024
      expect(vm_test.strand).to receive(:update).with(exitval: {msg: "exceeded read bw limit: 293601280"})
      expect { vm_test.verify_io_rates }.to hop("failed")
    end

    it "fails if write mbytes per sec exceeds the limit" do
      expect(vm_test).to receive(:get_read_bw_bytes).and_return 200 * 1024 * 1024
      expect(vm_test).to receive(:get_write_bw_bytes).and_return 320 * 1024 * 1024
      expect(vm_test.strand).to receive(:update).with(exitval: {msg: "exceeded write bw limit: 335544320"})
      expect { vm_test.verify_io_rates }.to hop("failed")
    end
  end

  describe "#ping_vms_in_subnet" do
    it "pings vm in same subnet and hops to next step" do
      expect(sshable).to receive(:_cmd).with("ping -c 2 1.1.1.2")
      expect(sshable).to receive(:_cmd).with("ping -c 2 192.168.0.2")
      expect(sshable).to receive(:_cmd).with("ping -c 2 2001:db8:85a2::2")
      expect(sshable).to receive(:_cmd).with("ping -c 2 fd01:db8:85a2::2")
      expect { vm_test.ping_vms_in_subnet }.to hop("ping_vms_not_in_subnet")
    end
  end

  describe "#ping_vms_not_in_subnet" do
    it "fails to ping private interfaces of vms not in the same subnect and hops to next step" do
      expect(sshable).to receive(:_cmd).with("ping -c 2 1.1.1.3")
      expect(sshable).to receive(:_cmd).with("ping -c 2 192.168.0.3").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect(sshable).to receive(:_cmd).with("ping -c 2 2001:db8:85a3::2")
      expect(sshable).to receive(:_cmd).with("ping -c 2 fd01:db8:85a3::2").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect { vm_test.ping_vms_not_in_subnet }.to hop("finish")
    end

    it "raises error if pinging private ipv4 of vms in other subnets succeed" do
      expect(sshable).to receive(:_cmd).with("ping -c 2 1.1.1.3")
      expect(sshable).to receive(:_cmd).with("ping -c 2 192.168.0.3")
      expect(sshable).to receive(:_cmd).with("ping -c 2 2001:db8:85a3::2")
      expect(sshable).to receive(:_cmd).with("ping -c 2 fd01:db8:85a3::2").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect { vm_test.ping_vms_not_in_subnet }.to raise_error RuntimeError, "Unexpected successful ping to private ip4 of a vm in different subnet"
    end

    it "raises error if pinging private ipv9 of vms in other subnets succeed" do
      expect(sshable).to receive(:_cmd).with("ping -c 2 1.1.1.3")
      expect(sshable).to receive(:_cmd).with("ping -c 2 2001:db8:85a3::2")
      expect(sshable).to receive(:_cmd).with("ping -c 2 fd01:db8:85a3::2")
      expect { vm_test.ping_vms_not_in_subnet }.to raise_error RuntimeError, "Unexpected successful ping to private ip6 of a vm in different subnet"
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
