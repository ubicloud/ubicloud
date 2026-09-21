# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::FirewallRules do
  subject(:firewall_test) {
    described_class.new(Strand.create_with_id(firewall.id, prog: "Test::FirewallRules", label: "start"))
  }

  let(:strand) { firewall_test.strand }

  let(:project) { Project.create(name: "project1") }

  let(:private_subnet_1) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps1", location_id: Location::HETZNER_FSN1_ID).subject
  }

  let(:private_subnet_2) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps2", location_id: Location::HETZNER_FSN1_ID).subject
  }

  let(:firewall) { private_subnet_1.firewalls.first }

  let(:vm_1) { create_test_vm(private_subnet_1, "vm1", "ubuntu-noble", "1.1.1.1", "2001:db8:85a1::/64") }

  let(:vm_2) { create_test_vm(private_subnet_1, "vm2", "almalinux-9", "2.2.2.2", "2001:db8:85a2::/64") }

  let(:vm_outside) { create_test_vm(private_subnet_2, "vm-outside", "debian-12", "3.3.3.3", "2001:db8:85a3::/64") }

  def create_test_vm(private_subnet, name, boot_image, ip4, net6)
    vm = Prog::Vm::Nexus.assemble_with_sshable(project.id, name:, boot_image:, private_subnet_id: private_subnet.id, location_id: Location::HETZNER_FSN1_ID).subject
    vm.update(ephemeral_net6: net6)
    add_ipv4_to_vm(vm, ip4)
    vm.strand.update(label: "wait")
    vm.reload
  end

  before do
    vm_1
    vm_2
    allow(firewall_test).to receive(:vm1) { vm_1 }
    allow(firewall_test).to receive(:vm2) { vm_2 }
    allow(firewall_test).to receive(:vm_outside) { vm_outside }
  end

  describe "#start" do
    before do
      allow(firewall_test).to receive(:frame).and_return({"vm_to_be_connected_id" => nil})
    end

    it "installs nc and sets up services" do
      expect(vm_2.sshable).to receive(:_cmd).with("sudo yum install -y nc")
      expect(vm_outside.sshable).to receive(:_cmd).with("sudo apt-get update && sudo apt-get install -y netcat-openbsd")
      expect(vm_1.sshable).to receive(:_cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/nc -l 8080
' | sudo tee /etc/systemd/system/listening_ipv4.service > /dev/null")
      expect(vm_1.sshable).to receive(:_cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=nc -l 8080 -6
' | sudo tee /etc/systemd/system/listening_ipv6.service > /dev/null")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl enable listening_ipv4.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl enable listening_ipv6.service")

      expect { firewall_test.start }.to hop("perform_tests_none")
      expect(firewall_test.strand.stack[0]["vm_to_be_connected_id"]).to eq vm_1.id
    end

    it "installs nc to other vms too" do
      allow(vm_1).to receive(:boot_image).and_return("almalinux-9")
      allow(vm_2).to receive(:boot_image).and_return("ubuntu-jammy")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo yum install -y nc")
      expect(vm_outside.sshable).to receive(:_cmd).with("sudo apt-get update && sudo apt-get install -y netcat-openbsd")

      expect(vm_1.sshable).to receive(:_cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/nc -l 8080
' | sudo tee /etc/systemd/system/listening_ipv4.service > /dev/null")
      expect(vm_1.sshable).to receive(:_cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=nc -l 8080 -6
' | sudo tee /etc/systemd/system/listening_ipv6.service > /dev/null")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl enable listening_ipv4.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl enable listening_ipv6.service")

      expect { firewall_test.start }.to hop("perform_tests_none")
      expect(firewall_test.strand.stack[0]["vm_to_be_connected_id"]).to eq vm_1.id
    end
  end

  describe "#perform_tests_none" do
    it "updates firewall rules when the frame is not set to none and naps if firewall rules are not updated" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => nil, "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_none)

      private_subnet_1.incr_update_firewall_rules
      expect { firewall_test.perform_tests_none }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "none"
    end

    it "doesn't update firewall rules when the frame is set to none and naps if firewall rules are not updated" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      vm_1.incr_update_firewall_rules
      expect { firewall_test.perform_tests_none }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "none"
    end

    it "doesn't update firewall rules when the frame is set to none and naps if a vm has not applied them yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      vm_1.strand.update(label: "update_firewall_rules")
      expect { firewall_test.perform_tests_none }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "none"
    end

    it "doesn't update firewall rules and tests connectivity and hops when the fw update is done" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      expect(vm_1.sshable).to receive(:_cmd).with("true")
      expect(vm_2.sshable).to receive(:_cmd).with("true")
      expect(vm_1.sshable).to receive(:_cmd).with("ping -c 2 google.com")
      expect(vm_2.sshable).to receive(:_cmd).with("ping -c 2 google.com")

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv4.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_raise("nc: connect to 1.1.1.1 port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_none }.to hop("perform_tests_public_ipv4")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "none"
    end

    it "updates firewall rules and tests connectivity and fails when the fw update is done" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      expect(vm_1.sshable).to receive(:_cmd).with("true")
      expect(vm_2.sshable).to receive(:_cmd).with("true")
      expect(vm_1.sshable).to receive(:_cmd).with("ping -c 2 google.com")
      expect(vm_2.sshable).to receive(:_cmd).with("ping -c 2 google.com")

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv4.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_return("success!")

      expect { firewall_test.perform_tests_none }.to hop("failed")
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_2.inhost_name} should not be able to connect to #{vm_1.inhost_name} on port 8080"})
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "none"
    end
  end

  describe "#perform_tests_public_ipv4" do
    it "updates firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "none", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv4)

      private_subnet_1.incr_update_firewall_rules
      expect { firewall_test.perform_tests_public_ipv4 }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv4"
    end

    it "does not update firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      vm_2.incr_update_firewall_rules
      expect { firewall_test.perform_tests_public_ipv4 }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv4"
    end

    it "does not update firewall rules but tests connectivity and fails when the VM2 cannot connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_raise("nc: connect to 1.1.1.1 port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_public_ipv4 }.to hop("failed")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv4"
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_2.inhost_name} should be able to connect to 1.1.1.1 on port 8080"})
    end

    it "updates firewall rules and tests connectivity and fails when the VM2 can connect to VM1 but also the vm_outside can connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv4)

      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_return("success!")
      expect(vm_outside.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_return("success!")

      expect { firewall_test.perform_tests_public_ipv4 }.to hop("failed")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv4"
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_outside.inhost_name} should not be able to connect to #{vm_1.inhost_name} on port 8080"})
    end

    it "updates firewall rules and tests connectivity and succeeds when the VM2 can connect to VM1 but not the vm_outside" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv4)

      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_return("success!")
      expect(vm_outside.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_raise("nc: connect to 1.1.1.1 port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_public_ipv4 }.to hop("perform_tests_public_ipv6")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv4"
    end
  end

  describe "#perform_tests_public_ipv6" do
    it "updates firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv6)

      private_subnet_1.incr_update_firewall_rules
      expect { firewall_test.perform_tests_public_ipv6 }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv6"
    end

    it "does not update firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      vm_2.incr_update_firewall_rules
      expect { firewall_test.perform_tests_public_ipv6 }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv6"
    end

    it "does not update firewall rules but tests connectivity and fails when the VM2 cannot connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv6)

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv6.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.ip6_string} 8080 -6").and_raise("nc: connect to #{vm_1.ip6_string} port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_public_ipv6 }.to hop("failed")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv6"
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_2.inhost_name} should be able to connect to #{vm_1.ip6_string} on port 8080"})
    end

    it "updates firewall rules and tests connectivity and fails when the VM2 can connect to VM1 but also the vm_outside can connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv6)

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv6.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.ip6_string} 8080 -6").and_return("success!")
      expect(vm_outside.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.ip6_string} 8080 -6").and_return("success!")

      expect { firewall_test.perform_tests_public_ipv6 }.to hop("failed")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv6"
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_outside.inhost_name} should not be able to connect to #{vm_1.ip6_string} on port 8080"})
    end

    it "updates firewall rules and tests connectivity and succeeds when the VM2 can connect to VM1 but not the vm_outside" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_public_ipv6)

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv6.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.ip6_string} 8080 -6").and_return("success!")
      expect(vm_outside.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.ip6_string} 8080 -6").and_raise("nc: connect to #{vm_1.ip6_string} port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_public_ipv6 }.to hop("perform_tests_private_ipv4")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "public_ipv6"
    end
  end

  describe "#perform_tests_private_ipv4" do
    it "updates firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "public_ipv6", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv4)

      private_subnet_1.incr_update_firewall_rules
      expect { firewall_test.perform_tests_private_ipv4 }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv4"
    end

    it "does not update firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      vm_2.incr_update_firewall_rules
      expect { firewall_test.perform_tests_private_ipv4 }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv4"
    end

    it "does not update firewall rules but tests connectivity and fails when the VM2 cannot connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv4)

      private_ipv4 = vm_1.user_nic.private_ipv4.nth(0)
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv4.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{private_ipv4} 8080").and_raise("nc: connect to #{private_ipv4} port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_private_ipv4 }.to hop("failed")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv4"
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_2.inhost_name} should be able to connect to #{private_ipv4} on port 8080"})
    end

    it "does not update firewall rules and tests connectivity and succeeds when the VM2 can connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv4)

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv4.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.user_nic.private_ipv4.nth(0)} 8080").and_return("success!")
      expect(vm_outside.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_raise("nc: connect to 1.1.1.1 port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_private_ipv4 }.to hop("perform_tests_private_ipv6")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv4"
    end

    it "does not update firewall rules and tests connectivity and fails when the vm_outside can connect to VM1 publicly" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv4)

      private_ipv4 = vm_1.user_nic.private_ipv4.nth(0)
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv4.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{private_ipv4} 8080").and_return("success!")
      expect(vm_outside.sshable).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_return("success!")

      expect { firewall_test.perform_tests_private_ipv4 }.to hop("failed")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv4"
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_outside.inhost_name} should not be able to connect to #{private_ipv4} on port 8080"})
    end
  end

  describe "#perform_tests_private_ipv6" do
    it "updates firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv4", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv6)

      private_subnet_1.incr_update_firewall_rules
      expect { firewall_test.perform_tests_private_ipv6 }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv6"
    end

    it "does not update firewall rules and naps when the fw update is not done yet" do
      expect(firewall_test).to receive(:frame).and_return({"firewalls" => "private_ipv6"})
      expect(firewall_test).not_to receive(:update_firewall_rules)

      vm_2.incr_update_firewall_rules
      expect { firewall_test.perform_tests_private_ipv6 }.to nap(5)
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv6"
    end

    it "does not update firewall rules but tests connectivity and fails when the VM2 cannot connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv6", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv6)

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv6.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.private_ipv6} 8080 -6").and_raise("nc: connect to #{vm_1.private_ipv6} port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_private_ipv6 }.to hop("failed")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv6"
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_2.inhost_name} should be able to connect to #{vm_1.private_ipv6} on port 8080"})
    end

    it "does not update firewall rules and tests connectivity and succeeds when the VM2 can connect to VM1" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv6", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv6)

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv6.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.private_ipv6} 8080 -6").and_return("success!")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.ip6_string} 8080 -6").and_raise("nc: connect to #{vm_1.ip6_string} port 8080 (tcp) timed out")

      expect { firewall_test.perform_tests_private_ipv6 }.to hop("finish")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv6"
    end

    it "does not update firewall rules and tests connectivity and fails when the vm2 can connect to VM1 publicly" do
      expect(firewall_test).to receive_messages(frame: {"firewalls" => "private_ipv6", "vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test).not_to receive(:update_firewall_rules).with(config: :perform_tests_private_ipv6)

      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(vm_1.sshable).to receive(:_cmd).with("sudo systemctl start listening_ipv6.service")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.private_ipv6} 8080 -6").and_return("success!")
      expect(vm_2.sshable).to receive(:_cmd).with("nc -zvw 1 #{vm_1.ip6_string} 8080 -6").and_return("success!")

      expect { firewall_test.perform_tests_private_ipv6 }.to hop("failed")
      expect(firewall_test.strand.stack[0]["firewalls"]).to eq "private_ipv6"
      expect(strand.reload.exitval).to eq({"msg" => "#{vm_2.inhost_name} should not be able to connect to #{vm_1.ip6_string} on port 8080"})
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

      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: vm_2.ip4_string, port_range: "8080..8080"}])
      firewall_test.update_firewall_rules(config: :perform_tests_public_ipv4)

      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: vm_2.ip6_string, port_range: "8080..8080"}])
      firewall_test.update_firewall_rules(config: :perform_tests_public_ipv6)

      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: vm_2.user_nic.private_ipv4.to_s, port_range: "8080..8080"}])
      firewall_test.update_firewall_rules(config: :perform_tests_private_ipv4)

      expect(firewall_test.firewall).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: vm_2.private_ipv6.to_s, port_range: "8080..8080"}])
      firewall_test.update_firewall_rules(config: :perform_tests_private_ipv6)

      expect { firewall_test.update_firewall_rules(config: :unknown) }.to raise_error("Unknown config: unknown")
    end
  end

  describe ".vm1" do
    it "returns the vm from the frame" do
      allow(firewall_test).to receive(:vm1).and_call_original
      expect(firewall_test).to receive_messages(frame: {"vm_to_be_connected_id" => vm_1.id})
      expect(firewall_test.vm1.id).to eq vm_1.id
    end
  end

  describe ".vm2" do
    it "returns the second vm" do
      allow(firewall_test).to receive(:vm1).and_call_original
      allow(firewall_test).to receive(:vm2).and_call_original
      expect(firewall_test.vm2.id).to eq(firewall.private_subnets.first.vms.last.id)
    end
  end

  describe ".vm_outside" do
    it "returns the first vm of the outside subnet from the frame" do
      allow(firewall_test).to receive(:vm_outside).and_call_original
      outside_id = vm_outside.id
      expect(firewall_test).to receive(:frame).and_return({"subnet_id_outside" => private_subnet_2.id})
      expect(firewall_test.vm_outside.id).to eq outside_id
    end
  end
end
