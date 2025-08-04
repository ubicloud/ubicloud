# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Test::ConnectedSubnets do
  subject(:connected_subnets_test) {
    described_class.new(Strand.new(prog: "Test::ConnectedSubnets"))
  }

  let(:ps_multiple) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps-multiple", location_id: Location::HETZNER_FSN1_ID).subject
  }

  let(:ps_single) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps-single", location_id: Location::HETZNER_FSN1_ID).subject
  }

  let(:project) {
    Project.create(name: "project1")
  }

  let(:sshable) {
    instance_double(Sshable)
  }

  before do
    ps_multiple
    ps_single
    allow(connected_subnets_test).to receive(:frame).and_return({"subnet_id_multiple" => ps_multiple.id, "subnet_id_single" => ps_single.id}).at_least(:once)
  end

  describe "#start" do
    it "updates firewall rules for both subnets, connects them, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_single, ps_multiple, config: :perform_tests_public_blocked)
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_single, config: :perform_tests_public_blocked)
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      vm1 = instance_double(Vm, id: "1ae5f1c2-2f48-4eac-84e3-cfe35b2a9865", sshable: sshable, ephemeral_net4: NetAddr::IPv4Net.parse("0.0.0.0"), boot_image: "debian-12")
      vm2 = instance_double(Vm, id: "3f2f4ed0-88b1-49c6-b66a-0d2ed4910ad0", sshable: sshable, boot_image: "almalinux-9")
      expect(ps_multiple).to receive(:vms).and_return([vm1, vm2]).at_least(:once)
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
      expect(connected_subnets_test).to receive(:update_stack).with({"vm_to_be_connected_id" => vm1.id})
      expect { connected_subnets_test.start }.to nap(5)
    end

    it "hops to perform_tests_public_blocked" do
      expect(connected_subnets_test).to receive(:frame).and_return({"vm_to_be_connected_id" => true})
      ps_multiple.strand.update(label: "wait")
      ps_single.strand.update(label: "wait")
      Semaphore.all.map(&:destroy)

      expect { connected_subnets_test.start }.to hop("perform_tests_public_blocked")
    end
  end

  describe "#perform_tests_public_blocked" do
    it "tests connection between the two subnets and fails" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      expect(connected_subnets_test).to receive(:ps_single).and_return(ps_single).at_least(:once)
      vm1 = instance_double(Vm, sshable: sshable, ephemeral_net4: NetAddr::IPv4Net.parse("0.0.0.0"))
      vm2 = instance_double(Vm, sshable: sshable)
      expect(ps_multiple).to receive(:vms).and_return([vm1, vm2]).at_least(:once)
      expect(ps_single).to receive(:vms).and_return([vm2]).at_least(:once)
      expect(sshable).to receive(:cmd).with("ping -c 2 google.com").at_least(:once)
      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.ephemeral_net4, vm2, should_fail: true, ipv4: true)

      expect { connected_subnets_test.perform_tests_public_blocked }.to hop("perform_tests_private_ipv4")
    end
  end

  describe "#perform_tests_private_ipv4" do
    it "updates firewall rules, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_single, config: :perform_connected_private_ipv4)
      expect(connected_subnets_test).to receive(:update_stack).with({"firewalls" => "connected_private_ipv4"})
      expect(ps_multiple).to receive(:update_firewall_rules_set?).and_return(true)
      expect { connected_subnets_test.perform_tests_private_ipv4 }.to nap(5)
    end

    it "tests connection between the two subnets and hops to perform_tests_private_ipv6" do
      expect(connected_subnets_test).to receive(:frame).and_return({"firewalls" => "connected_private_ipv4"})
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)

      vm1 = instance_double(Vm, sshable: sshable, nics: [instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.0/26"))])
      vm2 = instance_double(Vm)
      expect(connected_subnets_test).to receive(:vm_to_be_connected).and_return(vm1).at_least(:once)
      expect(connected_subnets_test).to receive(:vm_to_connect).and_return(vm2).at_least(:once)
      expect(connected_subnets_test).to receive(:vm_to_connect_outside).and_return(vm2).at_least(:once)

      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv4.nth(0).to_s, vm2, should_fail: false, ipv4: true)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv4.nth(0).to_s, vm2, should_fail: true, ipv4: true)

      expect { connected_subnets_test.perform_tests_private_ipv4 }.to hop("perform_tests_private_ipv6")
    end
  end

  describe "#perform_tests_private_ipv6" do
    it "updates firewall rules, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_single, config: :perform_connected_private_ipv6)
      expect(connected_subnets_test).to receive(:update_stack).with({"firewalls" => "connected_private_ipv6"})
      expect(ps_multiple).to receive(:update_firewall_rules_set?).and_return(true)
      expect { connected_subnets_test.perform_tests_private_ipv6 }.to nap(5)
    end

    it "tests connection between the two subnets and hops to perform_blocked_private_ipv4" do
      expect(connected_subnets_test).to receive(:frame).and_return({"firewalls" => "connected_private_ipv6"})
      vm1 = instance_double(Vm, sshable: sshable, nics: [instance_double(Nic, private_ipv6: NetAddr::IPv6Net.parse("2001:db8::/64"))], private_ipv6: NetAddr::IPv6.parse("2001:db8::2"))
      vm2 = instance_double(Vm)
      expect(connected_subnets_test).to receive(:vm_to_be_connected).and_return(vm1).at_least(:once)
      expect(connected_subnets_test).to receive(:vm_to_connect).and_return(vm2).at_least(:once)
      expect(connected_subnets_test).to receive(:vm_to_connect_outside).and_return(vm2).at_least(:once)

      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv6.nth(2).to_s, vm2, should_fail: false, ipv4: false)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv6.nth(2).to_s, vm2, should_fail: true, ipv4: false)

      expect { connected_subnets_test.perform_tests_private_ipv6 }.to hop("perform_blocked_private_ipv4")
    end
  end

  describe "#perform_blocked_private_ipv4" do
    it "updates firewall rules, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv4)
      expect(connected_subnets_test).to receive(:update_stack).with({"firewalls" => "blocked_private_ipv4"})
      expect(ps_multiple).to receive(:update_firewall_rules_set?).and_return(true)
      expect { connected_subnets_test.perform_blocked_private_ipv4 }.to nap(5)
    end

    it "tests connection between the two subnets and hops to perform_blocked_private_ipv6" do
      expect(connected_subnets_test).to receive(:frame).and_return({"firewalls" => "blocked_private_ipv4"})
      vm1 = instance_double(Vm, sshable: sshable, nics: [instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.0.0.0/26"))])
      vm2 = instance_double(Vm)
      expect(connected_subnets_test).to receive(:vm_to_be_connected).and_return(vm1).at_least(:once)
      expect(connected_subnets_test).to receive(:vm_to_connect).and_return(vm2).at_least(:once)
      expect(connected_subnets_test).to receive(:vm_to_connect_outside).and_return(vm2).at_least(:once)

      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv4.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv4.nth(0).to_s, vm2, should_fail: false, ipv4: true)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv4.nth(0).to_s, vm2, should_fail: true, ipv4: true)

      expect { connected_subnets_test.perform_blocked_private_ipv4 }.to hop("perform_blocked_private_ipv6")
    end
  end

  describe "#perform_blocked_private_ipv6" do
    it "updates firewall rules, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv6)
      expect(connected_subnets_test).to receive(:update_stack).with({"firewalls" => "blocked_private_ipv6"})
      expect(ps_multiple).to receive(:update_firewall_rules_set?).and_return(true)
      expect { connected_subnets_test.perform_blocked_private_ipv6 }.to nap(5)
    end

    it "tests connection between the two subnets and hops to perform_tests_public_blocked" do
      expect(connected_subnets_test).to receive(:frame).and_return({"firewalls" => "blocked_private_ipv6"})
      vm1 = instance_double(Vm, sshable: sshable, nics: [instance_double(Nic, private_ipv6: NetAddr::IPv6Net.parse("2001:db8::/64"))], private_ipv6: NetAddr::IPv6.parse("2001:db8::2"))
      vm2 = instance_double(Vm)
      expect(connected_subnets_test).to receive(:vm_to_be_connected).and_return(vm1).at_least(:once)
      expect(connected_subnets_test).to receive(:vm_to_connect).and_return(vm2).at_least(:once)
      expect(connected_subnets_test).to receive(:vm_to_connect_outside).and_return(vm2).at_least(:once)

      expect(sshable).to receive(:cmd).with("sudo systemctl start listening_ipv6.service")
      expect(sshable).to receive(:cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv6.nth(2).to_s, vm2, should_fail: false, ipv4: false)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv6.nth(2).to_s, vm2, should_fail: true, ipv4: false)

      expect { connected_subnets_test.perform_blocked_private_ipv6 }.to hop("finish")
    end
  end

  describe "#finish" do
    it "pops a message" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      expect(connected_subnets_test).to receive(:ps_single).and_return(ps_single).at_least(:once)
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, nil, config: :allow_all_traffic)
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_single, nil, config: :allow_all_traffic)
      expect(ps_multiple).to receive(:disconnect_subnet).with(ps_single)
      expect(connected_subnets_test).to receive(:pop).with("Verified Connected Subnets!")
      connected_subnets_test.finish
    end
  end

  describe "#failed" do
    it "naps" do
      expect(connected_subnets_test).to receive(:nap).with(15)
      connected_subnets_test.failed
    end
  end

  describe ".update_firewall_rules" do
    it "updates the firewall rules for different configurations" do
      expect(Sequel).to receive(:pg_range).with(22..22).and_return("22..22").at_least(:once)
      expect(Sequel).to receive(:pg_range).with(8080..8080).and_return("8080..8080").at_least(:once)
      expect(Sequel).to receive(:pg_range).with(0..65535).and_return("0..65535").at_least(:once)
      expect(Net::HTTP).to receive(:get).with(URI("https://api.ipify.org")).and_return("100.100.100.100").at_least(:once)
      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_multiple, config: :perform_tests_public_blocked)

      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: ps_single.net4.to_s, port_range: "8080..8080"}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_single, config: :perform_connected_private_ipv4)

      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: ps_single.net6.to_s, port_range: "8080..8080"}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_single, config: :perform_connected_private_ipv6)

      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: ps_multiple.net4.to_s, port_range: "8080..8080"}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv4)

      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: ps_multiple.net6.to_s, port_range: "8080..8080"}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv6)

      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: "22..22"}, {cidr: "0.0.0.0/0", port_range: "0..65535"}, {cidr: "::/0", port_range: "0..65535"}])
      connected_subnets_test.update_firewall_rules(ps_multiple, nil, config: :allow_all_traffic)

      expect { connected_subnets_test.update_firewall_rules(ps_multiple, ps_multiple, config: :unknown) }.to raise_error("Unknown config: unknown")
    end
  end

  describe ".vm_to_be_connected" do
    it "returns the vm to be connected" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      vm1 = instance_double(Vm)
      vm2 = instance_double(Vm)
      expect(ps_multiple).to receive(:vms).and_return([vm1, vm2]).at_least(:once)
      expect(connected_subnets_test.vm_to_be_connected).to eq(vm1)
    end

    it "returns the vm to be connected when already connected" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      vm1 = instance_double(Vm, id: "vm1")
      vm2 = instance_double(Vm, id: "vm2")
      expect(ps_multiple).to receive(:vms).and_return([vm1, vm2]).at_least(:once)
      expect(connected_subnets_test).to receive(:frame).and_return({"vm_to_be_connected_id" => vm2.id})
      expect(connected_subnets_test.vm_to_be_connected).to eq(vm2)
    end
  end

  describe ".vm_to_connect" do
    it "returns the vm to connect" do
      expect(connected_subnets_test).to receive(:ps_multiple).and_return(ps_multiple).at_least(:once)
      vm1 = instance_double(Vm, id: "vm1")
      vm2 = instance_double(Vm, id: "vm2")
      expect(ps_multiple).to receive(:vms).and_return([vm1, vm2]).at_least(:once)
      expect(connected_subnets_test.vm_to_connect).to eq(vm2)
    end
  end

  describe ".vm_to_connect_outside" do
    it "returns the vm to connect outside" do
      expect(connected_subnets_test).to receive(:ps_single).and_return(ps_single).at_least(:once)
      vm = instance_double(Vm)
      expect(ps_single).to receive(:vms).and_return([vm]).at_least(:once)
      expect(connected_subnets_test.vm_to_connect_outside).to eq(vm)
    end
  end

  describe ".test_connection" do
    it "tests the connection" do
      to_connect_ip = "1.1.1.1"
      connecting = instance_double(Vm, sshable: sshable, inhost_name: "connecting")
      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_return("success!")
      expect { connected_subnets_test.test_connection(to_connect_ip, connecting, should_fail: false, ipv4: true) }.not_to raise_error

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_raise("error")
      expect(connected_subnets_test).to receive(:fail_test).with("connecting should be able to connect to 1.1.1.1 on port 8080")
      connected_subnets_test.test_connection(to_connect_ip, connecting, should_fail: false, ipv4: true)

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 -6").and_return("success!")
      expect { connected_subnets_test.test_connection(to_connect_ip, connecting, should_fail: false, ipv4: false) }.not_to raise_error

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 -6").and_raise("error")
      expect(connected_subnets_test).to receive(:fail_test).with("connecting should be able to connect to 1.1.1.1 on port 8080")
      connected_subnets_test.test_connection(to_connect_ip, connecting, should_fail: false, ipv4: false)

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_return("success!")
      expect(connected_subnets_test).to receive(:fail_test).with("connecting should not be able to connect to 1.1.1.1 on port 8080")
      connected_subnets_test.test_connection(to_connect_ip, connecting, should_fail: true, ipv4: true)

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 -6").and_return("success!")
      expect(connected_subnets_test).to receive(:fail_test).with("connecting should not be able to connect to 1.1.1.1 on port 8080")
      connected_subnets_test.test_connection(to_connect_ip, connecting, should_fail: true, ipv4: false)

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 ").and_raise("error")
      expect(connected_subnets_test.test_connection(to_connect_ip, connecting, should_fail: true, ipv4: true)).to eq(0)

      expect(sshable).to receive(:cmd).with("nc -zvw 1 1.1.1.1 8080 -6").and_raise("error")
      expect(connected_subnets_test.test_connection(to_connect_ip, connecting, should_fail: true, ipv4: false)).to eq(0)
    end
  end
end
