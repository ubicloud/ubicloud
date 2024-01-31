# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Test::Vm do
  subject(:vm_test) {
    described_class.new(Strand.new(prog: "Test::Vm"))
  }

  let(:sshable) {
    instance_double(Sshable)
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
      ephemeral_net4: "1.1.1.1",
      ephemeral_net6: NetAddr::IPv6Net.parse("2001:0db8:85a1::/64"),
      nics: [nic1],
      vm_storage_volumes: [main_storage_volume, extra_storage_volume])

    nic2 = instance_double(Nic,
      private_ipv6: NetAddr::IPv6Net.parse("fd01:0db8:85a2::/64"),
      private_ipv4: NetAddr::IPv4Net.parse("192.168.0.2/32"))
    vm2 = instance_double(Vm, id: "vm2",
      private_subnets: [subnet1],
      ephemeral_net4: "1.1.1.2",
      ephemeral_net6: NetAddr::IPv6Net.parse("2001:0db8:85a2::/64"),
      nics: [nic2])

    nic3 = instance_double(Nic,
      private_ipv6: NetAddr::IPv6Net.parse("fd01:0db8:85a3::/64"),
      private_ipv4: NetAddr::IPv4Net.parse("192.168.0.3/32"))
    vm3 = instance_double(Vm, id: "vm3",
      private_subnets: [subnet2],
      ephemeral_net4: "1.1.1.3",
      ephemeral_net6: NetAddr::IPv6Net.parse("2001:0db8:85a3::/64"),
      nics: [nic3])

    project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
    allow(project).to receive(:vms).and_return([vm1, vm2, vm3])
    allow(vm1).to receive(:projects).and_return [project]
    allow(vm_test).to receive_messages(sshable: sshable, vm: vm1)
  }

  describe "#start" do
    it "hops to verify_dd" do
      expect { vm_test.start }.to hop("verify_dd")
    end
  end

  describe "#verify_dd" do
    it "verifies dd" do
      expect(sshable).to receive(:cmd).with("dd if=/dev/random of=~/1.txt bs=512 count=1000000")
      expect(sshable).to receive(:cmd).with("sync ~/1.txt")
      expect(sshable).to receive(:cmd).with("ls -s ~/1.txt").and_return "500004 /home/xyz/1.txt"
      expect { vm_test.verify_dd }.to hop("install_packages")
    end

    it "fails to verify if size is not in expected range" do
      expect(sshable).to receive(:cmd).with("dd if=/dev/random of=~/1.txt bs=512 count=1000000")
      expect(sshable).to receive(:cmd).with("sync ~/1.txt")
      expect(sshable).to receive(:cmd).with("ls -s ~/1.txt").and_return "300 /home/xyz/1.txt"
      expect(vm_test.strand).to receive(:update).with(exitval: {msg: "unexpected size after dd"})
      expect { vm_test.verify_dd }.to hop("failed")
    end
  end

  describe "#install_packages" do
    it "installs packages and hops to next step" do
      expect(sshable).to receive(:cmd).with("sudo apt update")
      expect(sshable).to receive(:cmd).with("sudo apt install -y build-essential")
      expect { vm_test.install_packages }.to hop("verify_extra_disks")
    end
  end

  describe "#verify_extra_disks" do
    it "verifies extra disks" do
      disk_path = "/dev/disk/by-id/disk_1"
      mount_path = "/home/ubi/mnt0"
      expect(sshable).to receive(:cmd).with("mkdir -p #{mount_path}")
      expect(sshable).to receive(:cmd).with("sudo mkfs.ext4 #{disk_path}")
      expect(sshable).to receive(:cmd).with("sudo mount #{disk_path} #{mount_path}")
      expect(sshable).to receive(:cmd).with("sudo chown ubi #{mount_path}")
      expect(sshable).to receive(:cmd).with("dd if=/dev/random of=#{mount_path}/1.txt bs=512 count=10000")
      expect(sshable).to receive(:cmd).with("sync #{mount_path}/1.txt")
      expect { vm_test.verify_extra_disks }.to hop("ping_google")
    end
  end

  describe "#ping_google" do
    it "pings google and hops to next step" do
      expect(sshable).to receive(:cmd).with("ping -c 2 google.com")
      expect { vm_test.ping_google }.to hop("ping_vms_in_subnet")
    end
  end

  describe "#ping_vms_in_subnet" do
    it "pings vm in same subnect and hops to next step" do
      expect(sshable).to receive(:cmd).with("ping -c 2 1.1.1.2")
      expect(sshable).to receive(:cmd).with("ping -c 2 192.168.0.2")
      expect(sshable).to receive(:cmd).with("ping -c 2 2001:db8:85a2::2")
      expect(sshable).to receive(:cmd).with("ping -c 2 fd01:db8:85a2::2")
      expect { vm_test.ping_vms_in_subnet }.to hop("ping_vms_not_in_subnet")
    end
  end

  describe "#ping_vms_not_in_subnet" do
    it "fails to ping private interfaces of vms not in the same subnect and hops to next step" do
      expect(sshable).to receive(:cmd).with("ping -c 2 1.1.1.3")
      expect(sshable).to receive(:cmd).with("ping -c 2 192.168.0.3").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect(sshable).to receive(:cmd).with("ping -c 2 2001:db8:85a3::2")
      expect(sshable).to receive(:cmd).with("ping -c 2 fd01:db8:85a3::2").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect { vm_test.ping_vms_not_in_subnet }.to hop("finish")
    end

    it "raises error if pinging private ipv4 of vms in other subnets succeed" do
      expect(sshable).to receive(:cmd).with("ping -c 2 1.1.1.3")
      expect(sshable).to receive(:cmd).with("ping -c 2 192.168.0.3")
      expect(sshable).to receive(:cmd).with("ping -c 2 2001:db8:85a3::2")
      expect(sshable).to receive(:cmd).with("ping -c 2 fd01:db8:85a3::2").and_raise Sshable::SshError.new("ping failed", "", "", nil, nil)
      expect { vm_test.ping_vms_not_in_subnet }.to raise_error RuntimeError, "Unexpected successful ping to private ip4 of a vm in different subnet"
    end

    it "raises error if pinging private ipv9 of vms in other subnets succeed" do
      expect(sshable).to receive(:cmd).with("ping -c 2 1.1.1.3")
      expect(sshable).to receive(:cmd).with("ping -c 2 2001:db8:85a3::2")
      expect(sshable).to receive(:cmd).with("ping -c 2 fd01:db8:85a3::2")
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
