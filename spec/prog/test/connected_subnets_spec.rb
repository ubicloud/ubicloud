# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Test::ConnectedSubnets do
  subject(:connected_subnets_test) {
    described_class.new(strand)
  }

  let(:strand) { Strand.create(prog: "Test::ConnectedSubnets", label: "start") }

  let(:project) {
    Project.create(name: "project1")
  }

  let(:vm1) {
    create_vm(
      name: "vm1", private_subnet: ps_multiple, boot_image: "debian-12",
      private_ipv4: "10.0.0.1/26", private_ipv6: "fd01:db8:85a1::/64",
      public_ipv4: "1.1.1.1/32"
    )
  }
  let(:vm2) {
    create_vm(
      name: "vm2", private_subnet: ps_multiple, boot_image: "almalinux-9",
      private_ipv4: "10.0.0.2/26", private_ipv6: "fd01:db8:85a2::/64",
      public_ipv4: "1.1.1.2/32"
    )
  }

  let(:vm3) {
    create_vm(
      name: "vm3", private_subnet: ps_single, boot_image: "ubuntu-jammy",
      private_ipv4: "10.0.1.1/26", private_ipv6: "fd01:db8:85b1::/64",
      public_ipv4: "1.1.1.3/32"
    )
  }

  let(:sshable1) { vm1.sshable }
  let(:sshable2) { vm2.sshable }
  let(:sshable3) { vm3.sshable }

  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:ps_multiple) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps-multiple", location_id:).subject
  }

  let(:ps_single) {
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "ps-single", location_id:).subject
  }

  def create_vm(name:, private_subnet:, boot_image: "ubuntu-jammy", private_ipv4: nil, private_ipv6: nil, public_ipv4: nil)
    st = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name:, private_subnet_id: private_subnet.id,
      location_id:, unix_user: "ubi", boot_image:
    )
    vm = st.subject
    nic = vm.nics.first
    nic.update(private_ipv4:, private_ipv6:) if private_ipv4 && private_ipv6
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: public_ipv4) if public_ipv4
    vm
  end

  before do
    refresh_frame(connected_subnets_test, new_frame: {"subnet_id_multiple" => ps_multiple.id, "subnet_id_single" => ps_single.id})
    connected_subnets_test.instance_variable_set(:@ps_multiple, ps_multiple)
    connected_subnets_test.instance_variable_set(:@ps_single, ps_single)
  end

  def setup_vm_associations
    ps_multiple.associations[:vms] = [vm1, vm2]
    ps_single.associations[:vms] = [vm3]
  end

  describe "#start" do
    before { setup_vm_associations }

    it "updates firewall rules for both subnets, connects them, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_single, ps_multiple, config: :perform_tests_public_blocked)
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_single, config: :perform_tests_public_blocked)
      expect(sshable1).to receive(:_cmd).with("sudo apt-get update && sudo apt-get install -y netcat-openbsd")
      expect(sshable2).to receive(:_cmd).with("sudo yum install -y nc")
      expect(sshable1).to receive(:_cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/nc -l 8080
' | sudo tee /etc/systemd/system/listening_ipv4.service > /dev/null")
      expect(sshable1).to receive(:_cmd).with("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=nc -l 8080 -6
' | sudo tee /etc/systemd/system/listening_ipv6.service > /dev/null")
      expect(sshable1).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sshable1).to receive(:_cmd).with("sudo systemctl enable listening_ipv4.service")
      expect(sshable1).to receive(:_cmd).with("sudo systemctl enable listening_ipv6.service")
      expect(connected_subnets_test).to receive(:update_stack).with({"vm_to_be_connected_id" => vm1.id})
      expect { connected_subnets_test.start }.to nap(5)
    end

    it "hops to perform_tests_public_blocked" do
      refresh_frame(connected_subnets_test, new_values: {"vm_to_be_connected_id" => true})
      ps_multiple.strand.update(label: "wait")
      ps_single.strand.update(label: "wait")
      Semaphore.all.map(&:destroy)

      expect { connected_subnets_test.start }.to hop("perform_tests_public_blocked")
    end
  end

  describe "#perform_tests_public_blocked" do
    before { setup_vm_associations }

    it "tests connection between the two subnets and fails" do
      expect(sshable1).to receive(:_cmd).with("ping -c 2 google.com")
      expect(sshable2).to receive(:_cmd).with("ping -c 2 google.com")
      expect(sshable3).to receive(:_cmd).with("ping -c 2 google.com")
      expect(connected_subnets_test).to receive(:start_listening).with(ipv4: true)
      expect(connected_subnets_test).to receive(:test_connection).with(kind_of(NetAddr::IPv4), vm3, should_fail: true, ipv4: true)
      expect { connected_subnets_test.perform_tests_public_blocked }.to hop("perform_tests_private_ipv4")
    end
  end

  describe "#perform_tests_private_ipv4" do
    before { setup_vm_associations }

    it "updates firewall rules, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_single, config: :perform_connected_private_ipv4)
      expect(connected_subnets_test).to receive(:update_stack).with({"firewalls" => "connected_private_ipv4"})
      ps_multiple.incr_update_firewall_rules
      expect { connected_subnets_test.perform_tests_private_ipv4 }.to nap(5)
    end

    it "tests connection between the two subnets and hops to perform_tests_private_ipv6" do
      refresh_frame(connected_subnets_test, new_values: {"firewalls" => "connected_private_ipv4"})
      expect(connected_subnets_test).to receive(:start_listening).with(ipv4: true)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv4.nth(0).to_s, vm3, should_fail: false, ipv4: true)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv4.nth(0).to_s, vm2, should_fail: true, ipv4: true)
      expect { connected_subnets_test.perform_tests_private_ipv4 }.to hop("perform_tests_private_ipv6")
    end
  end

  describe "#perform_tests_private_ipv6" do
    before { setup_vm_associations }

    it "updates firewall rules, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_single, config: :perform_connected_private_ipv6)
      expect(connected_subnets_test).to receive(:update_stack).with({"firewalls" => "connected_private_ipv6"})
      ps_multiple.incr_update_firewall_rules
      expect { connected_subnets_test.perform_tests_private_ipv6 }.to nap(5)
    end

    it "tests connection between the two subnets and hops to perform_blocked_private_ipv4" do
      refresh_frame(connected_subnets_test, new_values: {"firewalls" => "connected_private_ipv6"})
      expect(connected_subnets_test).to receive(:start_listening).with(ipv4: false)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.private_ipv6.to_s, vm3, should_fail: false, ipv4: false)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.private_ipv6.to_s, vm2, should_fail: true, ipv4: false)
      expect { connected_subnets_test.perform_tests_private_ipv6 }.to hop("perform_blocked_private_ipv4")
    end
  end

  describe "#perform_blocked_private_ipv4" do
    before { setup_vm_associations }

    it "updates firewall rules, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv4)
      expect(connected_subnets_test).to receive(:update_stack).with({"firewalls" => "blocked_private_ipv4"})
      ps_multiple.incr_update_firewall_rules
      expect { connected_subnets_test.perform_blocked_private_ipv4 }.to nap(5)
    end

    it "tests connection between the two subnets and hops to perform_blocked_private_ipv6" do
      refresh_frame(connected_subnets_test, new_values: {"firewalls" => "blocked_private_ipv4"})
      expect(connected_subnets_test).to receive(:start_listening).with(ipv4: true)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv4.nth(0).to_s, vm2, should_fail: false, ipv4: true)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.nics.first.private_ipv4.nth(0).to_s, vm3, should_fail: true, ipv4: true)
      expect { connected_subnets_test.perform_blocked_private_ipv4 }.to hop("perform_blocked_private_ipv6")
    end
  end

  describe "#perform_blocked_private_ipv6" do
    before { setup_vm_associations }

    it "updates firewall rules, updates the stack, and naps" do
      expect(connected_subnets_test).to receive(:update_firewall_rules).with(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv6)
      expect(connected_subnets_test).to receive(:update_stack).with({"firewalls" => "blocked_private_ipv6"})
      ps_multiple.incr_update_firewall_rules
      expect { connected_subnets_test.perform_blocked_private_ipv6 }.to nap(5)
    end

    it "tests connection between the two subnets and hops to finish" do
      refresh_frame(connected_subnets_test, new_values: {"firewalls" => "blocked_private_ipv6"})
      expect(connected_subnets_test).to receive(:start_listening).with(ipv4: false)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.private_ipv6.to_s, vm2, should_fail: false, ipv4: false)
      expect(connected_subnets_test).to receive(:test_connection).with(vm1.private_ipv6.to_s, vm3, should_fail: true, ipv4: false)
      expect { connected_subnets_test.perform_blocked_private_ipv6 }.to hop("finish")
    end
  end

  describe "#finish" do
    it "pops a message" do
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
    let(:port_22) { Sequel.pg_range(22..22) }
    let(:port_8080) { Sequel.pg_range(8080..8080) }
    let(:port_all) { Sequel.pg_range(0..65535) }

    before do
      allow(Net::HTTP).to receive(:get).with(URI("https://api.ipify.org")).and_return("100.100.100.100")
    end

    it "sets ssh-only rules for perform_tests_public_blocked" do
      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: port_22}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_multiple, config: :perform_tests_public_blocked)
    end

    it "allows ipv4 traffic from single subnet for perform_connected_private_ipv4" do
      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: port_22}, {cidr: ps_single.net4.to_s, port_range: port_8080}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_single, config: :perform_connected_private_ipv4)
    end

    it "allows ipv6 traffic from single subnet for perform_connected_private_ipv6" do
      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: port_22}, {cidr: ps_single.net6.to_s, port_range: port_8080}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_single, config: :perform_connected_private_ipv6)
    end

    it "allows ipv4 traffic from multiple subnet for perform_blocked_private_ipv4" do
      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: port_22}, {cidr: ps_multiple.net4.to_s, port_range: port_8080}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv4)
    end

    it "allows ipv6 traffic from multiple subnet for perform_blocked_private_ipv6" do
      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: port_22}, {cidr: ps_multiple.net6.to_s, port_range: port_8080}])
      connected_subnets_test.update_firewall_rules(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv6)
    end

    it "allows all traffic for allow_all_traffic" do
      expect(ps_multiple.firewalls.first).to receive(:replace_firewall_rules).with([{cidr: "100.100.100.100/32", port_range: port_22}, {cidr: "0.0.0.0/0", port_range: port_all}, {cidr: "::/0", port_range: port_all}])
      connected_subnets_test.update_firewall_rules(ps_multiple, nil, config: :allow_all_traffic)
    end

    it "raises error for unknown config" do
      expect { connected_subnets_test.update_firewall_rules(ps_multiple, ps_multiple, config: :unknown) }.to raise_error("Unknown config: unknown")
    end
  end

  describe ".vm_to_be_connected" do
    before { setup_vm_associations }

    it "returns the vm to be connected" do
      expect(connected_subnets_test.vm_to_be_connected).to eq(vm1)
    end

    it "returns the vm to be connected when already connected" do
      refresh_frame(connected_subnets_test, new_values: {"vm_to_be_connected_id" => vm2.id})
      expect(connected_subnets_test.vm_to_be_connected).to eq(vm2)
    end
  end

  describe ".vm_to_connect" do
    before { setup_vm_associations }

    it "returns the vm to connect" do
      expect(connected_subnets_test.vm_to_connect).to eq(vm2)
    end
  end

  describe ".vm_to_connect_outside" do
    before { setup_vm_associations }

    it "returns the vm to connect outside" do
      expect(connected_subnets_test.vm_to_connect_outside).to eq(vm3)
    end
  end

  describe ".start_listening" do
    before { setup_vm_associations }

    it "starts ipv4 listener and stops ipv6" do
      expect(sshable1).to receive(:_cmd).with("sudo systemctl stop listening_ipv6.service")
      expect(sshable1).to receive(:_cmd).with("sudo systemctl start listening_ipv4.service")
      connected_subnets_test.start_listening(ipv4: true)
    end

    it "starts ipv6 listener and stops ipv4" do
      expect(sshable1).to receive(:_cmd).with("sudo systemctl stop listening_ipv4.service")
      expect(sshable1).to receive(:_cmd).with("sudo systemctl start listening_ipv6.service")
      connected_subnets_test.start_listening(ipv4: false)
    end
  end

  describe ".test_connection" do
    before { setup_vm_associations }

    let(:to_connect_ip) { "1.1.1.1" }

    it "succeeds with ipv4 when connection succeeds and should_fail is false" do
      expect(sshable2).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_return("success!")
      expect { connected_subnets_test.test_connection(to_connect_ip, vm2, should_fail: false, ipv4: true) }.not_to raise_error
    end

    it "fails with ipv4 when connection fails and should_fail is false" do
      expect(sshable2).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_raise("error")
      expect(connected_subnets_test).to receive(:fail_test).with("#{vm2.inhost_name} should be able to connect to 1.1.1.1 on port 8080")
      connected_subnets_test.test_connection(to_connect_ip, vm2, should_fail: false, ipv4: true)
    end

    it "succeeds with ipv6 when connection succeeds and should_fail is false" do
      expect(sshable2).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080 -6").and_return("success!")
      expect { connected_subnets_test.test_connection(to_connect_ip, vm2, should_fail: false, ipv4: false) }.not_to raise_error
    end

    it "fails with ipv6 when connection fails and should_fail is false" do
      expect(sshable2).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080 -6").and_raise("error")
      expect(connected_subnets_test).to receive(:fail_test).with("#{vm2.inhost_name} should be able to connect to 1.1.1.1 on port 8080")
      connected_subnets_test.test_connection(to_connect_ip, vm2, should_fail: false, ipv4: false)
    end

    it "fails with ipv4 when connection succeeds but should_fail is true" do
      expect(sshable2).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_return("success!")
      expect(connected_subnets_test).to receive(:fail_test).with("#{vm2.inhost_name} should not be able to connect to 1.1.1.1 on port 8080")
      connected_subnets_test.test_connection(to_connect_ip, vm2, should_fail: true, ipv4: true)
    end

    it "fails with ipv6 when connection succeeds but should_fail is true" do
      expect(sshable2).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080 -6").and_return("success!")
      expect(connected_subnets_test).to receive(:fail_test).with("#{vm2.inhost_name} should not be able to connect to 1.1.1.1 on port 8080")
      connected_subnets_test.test_connection(to_connect_ip, vm2, should_fail: true, ipv4: false)
    end

    it "returns 0 with ipv4 when connection fails and should_fail is true" do
      expect(sshable2).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080").and_raise("error")
      expect(connected_subnets_test.test_connection(to_connect_ip, vm2, should_fail: true, ipv4: true)).to eq(0)
    end

    it "returns 0 with ipv6 when connection fails and should_fail is true" do
      expect(sshable2).to receive(:_cmd).with("nc -zvw 1 1.1.1.1 8080 -6").and_raise("error")
      expect(connected_subnets_test.test_connection(to_connect_ip, vm2, should_fail: true, ipv4: false)).to eq(0)
    end
  end
end
