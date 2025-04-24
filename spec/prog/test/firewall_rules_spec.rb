# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Test::FirewallRules do
  subject(:firewall_test) {
    described_class.new(Strand.new(prog: "Test::FirewallRules"))
  }

  let(:sshable) {
    instance_double(Sshable)
  }

  let(:private_subnet_1) {
    nic = instance_double(Nic, private_ipv6: NetAddr::IPv6Net.parse("fd01:0db8:85a1::/64"), private_ipv4: NetAddr::IPv4Net.parse("192.168.0.1/32"))
    vm_1 = instance_double(Vm, id: "vm_1", sshable: sshable, boot_image: "ubuntu-noble", ephemeral_net4: "1.1.1.1", ephemeral_net6: NetAddr::IPv6Net.parse("2001:0db8:85a1::/64"), inhost_name: "vm1", nics: [nic], private_ipv6: NetAddr::IPv6.parse("fd01:0db8:85a1::2"))
    vm_2 = instance_double(Vm, id: "vm_2", sshable: sshable, boot_image: "almalinux-9", ephemeral_net4: "1.1.1.2", ephemeral_net6: NetAddr::IPv6Net.parse("2001:0db8:85a2::/64"), inhost_name: "vm2", nics: [nic], private_ipv6: NetAddr::IPv6.parse("fd01:0db8:85a2::2"))
    instance_double(PrivateSubnet, id: "subnet_1", vms: [vm_1, vm_2])
  }

  let(:vm_outside) {
    instance_double(Vm, id: "vm_outside", sshable: sshable, boot_image: "debian-12", ephemeral_net4: "1.1.1.3", ephemeral_net6: NetAddr::IPv6Net.parse("2001:0db8:85a3::/64"), inhost_name: "vm_outside")
  }

  before do
    fw = instance_double(Firewall, id: "fw_id", private_subnets: [private_subnet_1])
    allow(firewall_test).to receive(:firewall).and_return(fw)
  end

  describe "#start" do
    before do
      allow(firewall_test).to receive(:frame).and_return({"vm_to_be_connected_id" => nil})
    end

    it "installs nc and sets up services" do
      ps = instance_double(PrivateSubnet, id: "ps2", vms: [vm_outside])
      expect(firewall_test).to receive(:vm1).and_return(private_subnet_1.vms.first).at_least(:once)
      expect(firewall_test).to receive(:vm2).and_return(private_subnet_1.vms.last).at_least(:once)
      expect(firewall_test).to receive(:vm_outside).and_return(ps.vms.first).at_least(:once)
      expect(sshable).to receive(:cmd).with("sudo yum install -y nc")
      expect(sshable).to receive(:cmd).with("sudo apt-get update && sudo apt-get install -y netcat-openbsd")
      expect(sshable).to receive(:cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/nc -l 8080
' | sudo tee /etc/systemd/system/listening_ipv4.service > /dev/null")
      expect(sshable).to receive(:cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=nc -l 8080 -6
' | sudo tee /etc/systemd/system/listening_ipv6.service > /dev/null")
      expect(sshable).to receive(:cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:cmd).with("sudo systemctl enable listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl enable listening_ipv6.service")

      expect(firewall_test).to receive(:update_stack).with({"vm_to_be_connected_id" => "vm_1"})

      expect { firewall_test.start }.to hop("perform_tests_none")
    end

    it "installs nc to other vms too" do
      ps = instance_double(PrivateSubnet, id: "ps2", vms: [vm_outside])
      expect(firewall_test).to receive(:vm1).and_return(private_subnet_1.vms.first).at_least(:once)
      expect(firewall_test).to receive(:vm2).and_return(private_subnet_1.vms.last).at_least(:once)
      expect(firewall_test).to receive(:vm_outside).and_return(ps.vms.first).at_least(:once)

      expect(firewall_test.vm1).to receive(:boot_image).and_return("almalinux-9")
      expect(firewall_test.vm2).to receive(:boot_image).and_return("ubuntu-jammy")
      expect(sshable).to receive(:cmd).with("sudo yum install -y nc")
      expect(sshable).to receive(:cmd).with("sudo apt-get update && sudo apt-get install -y netcat-openbsd")

      expect(sshable).to receive(:cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/nc -l 8080
' | sudo tee /etc/systemd/system/listening_ipv4.service > /dev/null")
      expect(sshable).to receive(:cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=nc -l 8080 -6
' | sudo tee /etc/systemd/system/listening_ipv6.service > /dev/null")
      expect(sshable).to receive(:cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:cmd).with("sudo systemctl enable listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl enable listening_ipv6.service")

      expect(firewall_test).to receive(:update_stack).with({"vm_to_be_connected_id" => "vm_1"})

      expect { firewall_test.start }.to hop("perform_tests_none")
    end
  end

  describe "#perform_tests_none" do
    it "updates firewall rules when the frame is not set to none and naps if firewall rules are not updated" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => nil, "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_none)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "none"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_none }.to nap(5)
    end

    it "doesn't update firewall rules when the frame is set to none and naps if firewall rules are not updated" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "none"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_none }.to nap(5)
    end

    it "doesn't update firewall rules and tests connectivity and hops when the fw update is done" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "none"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("true").twice
      expect(sshable).to receive(:cmd).with("ping -c 2 google.com").twice

      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_raise("nc: connect to 1.1.1.1 port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_none }.to hop("perform_tests_public_ipv4")
    end

    it "updates firewall rules and tests connectivity and fails when the fw update is done" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "none"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("true").twice
      expect(sshable).to receive(:cmd).with("ping -c 2 google.com").twice

      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_return("success!")

      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm2 should not be able to connect to vm1 on port 8080"})
      expect { firewall_test.perform_tests_none }.to hop("failed")
    end
  end

  describe "#perform_tests_public_ipv4" do
    it "updates firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv4)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_public_ipv4 }.to nap(5)
    end

    it "does not update firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_public_ipv4 }.to nap(5)
    end

    it "does not update firewall rules but tests connectivity and fails when the VM2 cannot connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_raise("nc: connect to 1.1.1.1 port 8080 (tcp) timed out")
      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm2 should be able to connect to 1.1.1.1 on port 8080"})
      expect { firewall_test.perform_tests_public_ipv4 }.to hop("failed")
    end

    it "updates firewall rules and tests connectivity and fails when the VM2 can connect to VM1 but also the vm_outside can connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv4)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_return("success!").at_least(:once)

      vm_outside = instance_double(Vm, ephemeral_net4: "1.1.1.3", inhost_name: "vm_outside", sshable: sshable)
      expect(firewall_test).to receive(:vm_outside).and_return(vm_outside).at_least(:once)
      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm_outside should not be able to connect to vm1 on port 8080"})
      expect { firewall_test.perform_tests_public_ipv4 }.to hop("failed")
    end

    it "updates firewall rules and tests connectivity and succeeds when the VM2 can connect to VM1 but not the vm_outside" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv4)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_return("success!").once

      vm_outside = instance_double(Vm, ephemeral_net4: "1.1.1.3", inhost_name: "vm_outside", sshable: sshable)
      expect(firewall_test).to receive(:vm_outside).and_return(vm_outside).at_least(:once)
      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_raise("nc: connect to 1.1.1.1 port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_public_ipv4 }.to hop("perform_tests_public_ipv6")
    end
  end

  describe "#perform_tests_public_ipv6" do
    it "updates firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv6)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_public_ipv6 }.to nap(5)
    end

    it "does not update firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_public_ipv6 }.to nap(5)
    end

    it "does not update firewall rules but tests connectivity and fails when the VM2 cannot connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv6)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 2001:db8:85a1::2 8080 -6").and_raise("nc: connect to 2001:db8:85a1::/64 port 8080 (tcp) timed out")

      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm2 should be able to connect to 2001:db8:85a1::2 on port 8080"})
      expect { firewall_test.perform_tests_public_ipv6 }.to hop("failed")
    end

    it "updates firewall rules and tests connectivity and fails when the VM2 can connect to VM1 but also the vm_outside can connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv6)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv6.service")

      vm_outside = instance_double(Vm, inhost_name: "vm_outside", sshable: sshable)
      expect(firewall_test).to receive(:vm_outside).and_return(vm_outside).at_least(:once)
      expect(sshable).to receive(:cmd).with("nc -zvw 1 2001:db8:85a1::2 8080 -6").and_return("success!").at_least(:once)
      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm_outside should not be able to connect to 2001:db8:85a1::2 on port 8080"})
      expect { firewall_test.perform_tests_public_ipv6 }.to hop("failed")
    end

    it "updates firewall rules and tests connectivity and succeeds when the VM2 can connect to VM1 but not the vm_outside" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv6)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "public_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 2001:db8:85a1::2 8080 -6").and_return("success!").once

      vm_outside = instance_double(Vm, inhost_name: "vm_outside", sshable: sshable)
      expect(firewall_test).to receive(:vm_outside).and_return(vm_outside).at_least(:once)
      expect(sshable).to receive(:cmd).with("nc -zvw 1 2001:db8:85a1::2 8080 -6").and_raise("nc: connect to 2001:db8:85a1::/64 port 8080 (tcp) timed out")
      expect { firewall_test.perform_tests_public_ipv6 }.to hop("perform_tests_private_ipv4")
    end
  end

  describe "#perform_tests_private_ipv4" do
    it "updates firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv4)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_private_ipv4 }.to nap(5)
    end

    it "does not update firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_private_ipv4 }.to nap(5)
    end

    it "does not update firewall rules but tests connectivity and fails when the VM2 cannot connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv4)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 192.168.0.1 8080 ").and_raise("nc: connect to 192.168.0.1 port 8080 (tcp) timed out")
      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm2 should be able to connect to 192.168.0.1 on port 8080"})
      expect { firewall_test.perform_tests_private_ipv4 }.to hop("failed")
    end

    it "does not update firewall rules and tests connectivity and succeeds when the VM2 can connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv4)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 192.168.0.1 8080 ").and_return("success!").once

      vm_outside = instance_double(Vm, ephemeral_net4: "1.1.1.3", inhost_name: "vm_outside", sshable: sshable)
      expect(firewall_test).to receive(:vm_outside).and_return(vm_outside).at_least(:once)
      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_raise("nc: connect to 1.1.1.1 port 8080 (tcp) timed out")
      expect { firewall_test.perform_tests_private_ipv4 }.to hop("perform_tests_private_ipv6")
    end

    it "does not update firewall rules and tests connectivity and fails when the vm_outside can connect to VM1 publicly" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv4)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv4"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 192.168.0.1 8080 ").and_return("success!").once

      vm_outside = instance_double(Vm, ephemeral_net4: "1.1.1.3", inhost_name: "vm_outside", sshable: sshable)
      expect(firewall_test).to receive(:vm_outside).and_return(vm_outside).at_least(:once)
      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_return("success!").once
      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm_outside should not be able to connect to 192.168.0.1 on port 8080"})
      expect { firewall_test.perform_tests_private_ipv4 }.to hop("failed")
    end
  end

  describe "#perform_tests_private_ipv6" do
    it "updates firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv6)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_private_ipv6 }.to nap(5)
    end

    it "does not update firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive(:frame).and_return({"firewalls" => "private_ipv6"})
      expect(firewall_test).not_to receive(:update_firewall_rules)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(true)
      expect { firewall_test.perform_tests_private_ipv6 }.to nap(5)
    end

    it "does not update firewall rules but tests connectivity and fails when the VM2 cannot connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv6", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv6)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 fd01:db8:85a1::2 8080 -6").and_raise("nc: connect to fd01:0db8:85a1::2 port 8080 (tcp) timed out")
      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm2 should be able to connect to fd01:db8:85a1::2 on port 8080"})
      expect { firewall_test.perform_tests_private_ipv6 }.to hop("failed")
    end

    it "does not update firewall rules and tests connectivity and succeeds when the VM2 can connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv6", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv6)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 fd01:db8:85a1::2 8080 -6").and_return("success!").once
      expect(sshable).to receive(:cmd).with("nc -zvw 1 2001:db8:85a1::2 8080 -6").and_raise("nc: connect to 2001:db8:85a1::2 port 8080 (tcp) timed out")
      expect { firewall_test.perform_tests_private_ipv6 }.to hop("finish")
    end

    it "does not update firewall rules and tests connectivity and fails when the vm2 can connect to VM1 publicly" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv6", "vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv6)
      expect(firewall_test).to receive(:update_stack).with({"firewalls" => "private_ipv6"})

      expect(private_subnet_1).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.first).to receive(:update_firewall_rules_set?).and_return(false)
      expect(firewall_test.firewall.private_subnets.first.vms.last).to receive(:update_firewall_rules_set?).and_return(false)

      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 fd01:db8:85a1::2 8080 -6").and_return("success!").once
      expect(sshable).to receive(:cmd).with("nc -zvw 1 2001:db8:85a1::2 8080 -6").and_return("success!").once
      expect(firewall_test.strand).to receive(:update).with(exitval: {msg: "vm2 should not be able to connect to 2001:db8:85a1::2 on port 8080"})
      expect { firewall_test.perform_tests_private_ipv6 }.to hop("failed")
    end
  end

  describe "#finish" do
    it "pops the message" do
      expect(firewall_test).to receive(:pop).with("Verified Firewall Rules!")
      firewall_test.finish
    end
  end

  describe "#failed" do
    it "naps for 15 seconds" do
      expect(firewall_test).to receive(:nap).with(15)
      firewall_test.failed
    end
  end

  describe ".update_firewall_rules" do
    it "updates the firewall rules for different configurations" do
      expect(Sequel).to receive(:pg_range).with(22..22).and_return("22..22").at_least(:once)
      expect(Sequel).to receive(:pg_range).with(8080..8080).and_return("8080..8080").at_least(:once)
      expect(Net::HTTP).to receive(:get).with(URI("https://api.ipify.org")).and_return("100.100.100.100").at_least(:once)
      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}])
      firewall_test.update_firewall_rules(config: :perform_tests_none)

      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: "1.1.1.2", port_range: "8080..8080"}])
      firewall_test.update_firewall_rules(config: :perform_tests_public_ipv4)

      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: "2001:db8:85a2::2", port_range: "8080..8080"}])
      firewall_test.update_firewall_rules(config: :perform_tests_public_ipv6)

      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: "192.168.0.1/32", port_range: "8080..8080"}])
      firewall_test.update_firewall_rules(config: :perform_tests_private_ipv4)

      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: "fd01:db8:85a2::2", port_range: "8080..8080"}])
      firewall_test.update_firewall_rules(config: :perform_tests_private_ipv6)

      expect { firewall_test.update_firewall_rules(config: :unknown) }.to raise_error("Unknown config: unknown")
    end
  end

  describe ".vm1" do
    it "returns the first vm" do
      expect(firewall_test).to receive_messages(frame: {"vm_to_be_connected_id" => "vm_1"})
      expect(firewall_test.vm1).to eq(firewall_test.firewall.private_subnets.first.vms.first)
    end
  end

  describe ".vm2" do
    it "returns the second vm" do
      expect(firewall_test.vm2).to eq(firewall_test.firewall.private_subnets.first.vms.last)
    end
  end

  describe ".vm_outside" do
    it "returns the vm outside" do
      expect(firewall_test.vm1).to receive(:private_subnets).and_return([instance_double(PrivateSubnet, id: "ps1", vms: [instance_double(Vm, inhost_name: "vm1")])])
      prj = Project.create_with_id(name: "project1")
      ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps2", location_id: Location::HETZNER_FSN1_ID)
      Prog::Vm::Nexus.assemble("a a", prj.id, name: "vm-outside", location_id: Location::HETZNER_FSN1_ID, private_subnet_id: ps.id).subject
      expect(firewall_test.vm_outside.name).to eq("vm-outside")
    end
  end
end
