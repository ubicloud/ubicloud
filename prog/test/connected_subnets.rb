# frozen_string_literal: true

require "net/http"
require "uri"

class Prog::Test::ConnectedSubnets < Prog::Test::Base
  label def start
    unless frame["vm_to_be_connected_id"]
      pss.map(&:vms).flatten.each do |vm|
        vm.sshable.cmd("sudo yum install -y nc") if vm.boot_image.include?("almalinux")
        vm.sshable.cmd("sudo apt-get update && sudo apt-get install -y netcat-openbsd") if vm.boot_image.include?("debian")
      end

      vm_to_be_connected.sshable.cmd("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/nc -l 8080
' | sudo tee /etc/systemd/system/listening_ipv4.service > /dev/null")

      vm_to_be_connected.sshable.cmd("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=nc -l 8080 -6
' | sudo tee /etc/systemd/system/listening_ipv6.service > /dev/null")
      vm_to_be_connected.sshable.cmd("sudo systemctl daemon-reload")
      vm_to_be_connected.sshable.cmd("sudo systemctl enable listening_ipv4.service")
      vm_to_be_connected.sshable.cmd("sudo systemctl enable listening_ipv6.service")

      update_firewall_rules(ps_multiple, ps_single, config: :perform_tests_public_blocked)
      update_firewall_rules(ps_single, ps_multiple, config: :perform_tests_public_blocked)
      ps_multiple.connect_subnet(ps_single)
      update_stack({"vm_to_be_connected_id" => vm_to_be_connected.id})
    end

    unless ps_multiple.strand.label == "wait" && ps_single.strand.label == "wait" &&
        !ps_multiple.refresh_keys_set? && !ps_single.refresh_keys_set? &&
        !ps_multiple.update_firewall_rules_set? && !ps_single.update_firewall_rules_set?
      nap 5
    end

    hop_perform_tests_public_blocked
  end

  label def perform_tests_public_blocked
    pss.each do |ps|
      ps.vms.each do |vm|
        vm.sshable.cmd("ping -c 2 google.com")
      end
    end

    start_listening(ipv4: true)
    test_connection(vm_to_be_connected.ip4, vm_to_connect_outside, should_fail: true, ipv4: true)
    hop_perform_tests_private_ipv4
  end

  label def perform_tests_private_ipv4
    unless frame["firewalls"] == "connected_private_ipv4"
      update_firewall_rules(ps_multiple, ps_single, config: :perform_connected_private_ipv4)
      update_stack({"firewalls" => "connected_private_ipv4"})
    end

    if ps_multiple.update_firewall_rules_set? || ps_multiple.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    start_listening(ipv4: true)
    test_connection(vm_to_be_connected.nics.first.private_ipv4.nth(0).to_s, vm_to_connect_outside, should_fail: false, ipv4: true)
    test_connection(vm_to_be_connected.nics.first.private_ipv4.nth(0).to_s, vm_to_connect, should_fail: true, ipv4: true)

    hop_perform_tests_private_ipv6
  end

  label def perform_tests_private_ipv6
    unless frame["firewalls"] == "connected_private_ipv6"
      update_firewall_rules(ps_multiple, ps_single, config: :perform_connected_private_ipv6)
      update_stack({"firewalls" => "connected_private_ipv6"})
    end

    if ps_multiple.update_firewall_rules_set? || ps_multiple.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    start_listening(ipv4: false)

    test_connection(vm_to_be_connected.private_ipv6.to_s, vm_to_connect_outside, should_fail: false, ipv4: false)
    test_connection(vm_to_be_connected.private_ipv6.to_s, vm_to_connect, should_fail: true, ipv4: false)

    hop_perform_blocked_private_ipv4
  end

  label def perform_blocked_private_ipv4
    unless frame["firewalls"] == "blocked_private_ipv4"
      update_firewall_rules(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv4)
      update_stack({"firewalls" => "blocked_private_ipv4"})
    end

    if ps_multiple.update_firewall_rules_set? || ps_multiple.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    start_listening(ipv4: true)
    test_connection(vm_to_be_connected.nics.first.private_ipv4.nth(0).to_s, vm_to_connect, should_fail: false, ipv4: true)
    test_connection(vm_to_be_connected.nics.first.private_ipv4.nth(0).to_s, vm_to_connect_outside, should_fail: true, ipv4: true)

    hop_perform_blocked_private_ipv6
  end

  label def perform_blocked_private_ipv6
    unless frame["firewalls"] == "blocked_private_ipv6"
      update_firewall_rules(ps_multiple, ps_multiple, config: :perform_blocked_private_ipv6)
      update_stack({"firewalls" => "blocked_private_ipv6"})
    end

    if ps_multiple.update_firewall_rules_set? || ps_multiple.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    start_listening(ipv4: false)
    test_connection(vm_to_be_connected.private_ipv6.to_s, vm_to_connect, should_fail: false, ipv4: false)
    test_connection(vm_to_be_connected.private_ipv6.to_s, vm_to_connect_outside, should_fail: true, ipv4: false)

    hop_finish
  end

  label def finish
    ps_multiple.disconnect_subnet(ps_single)
    update_firewall_rules(ps_multiple, nil, config: :allow_all_traffic)
    update_firewall_rules(ps_single, nil, config: :allow_all_traffic)
    pop "Verified Connected Subnets!"
  end

  label def failed
    nap 15
  end

  def update_firewall_rules(ps_to_be_connected, ps_to_connect, config: nil)
    firewall = ps_to_be_connected.firewalls.first
    uri = URI("https://api.ipify.org")
    my_ip = Net::HTTP.get(uri)
    firewall_rules = [
      {cidr: "#{my_ip}/32", port_range: Sequel.pg_range(22..22)}
    ]
    firewall_rules << case config
    when :perform_tests_public_blocked
      nil
    when :perform_connected_private_ipv4
      {cidr: ps_to_connect.net4.to_s, port_range: Sequel.pg_range(8080..8080)}
    when :perform_connected_private_ipv6
      {cidr: ps_to_connect.net6.to_s, port_range: Sequel.pg_range(8080..8080)}
    when :perform_blocked_private_ipv4
      {cidr: ps_to_be_connected.net4.to_s, port_range: Sequel.pg_range(8080..8080)}
    when :perform_blocked_private_ipv6
      {cidr: ps_to_be_connected.net6.to_s, port_range: Sequel.pg_range(8080..8080)}
    when :allow_all_traffic
      [{cidr: "0.0.0.0/0", port_range: Sequel.pg_range(0..65535)}, {cidr: "::/0", port_range: Sequel.pg_range(0..65535)}]
    else
      raise "Unknown config: #{config}"
    end

    firewall.replace_firewall_rules(firewall_rules.flatten.compact)
  end

  def ps_multiple
    @ps_multiple ||= PrivateSubnet[frame["subnet_id_multiple"]]
  end

  def ps_single
    @ps_single ||= PrivateSubnet[frame["subnet_id_single"]]
  end

  def pss
    @pss ||= [ps_multiple, ps_single]
  end

  def vm_to_be_connected
    connected_id = frame["vm_to_be_connected_id"]
    @vm_to_be_connected ||= if connected_id
      ps_multiple.vms.find { |vm| vm.id == connected_id }
    else
      ps_multiple.vms.first
    end
  end

  def vm_to_connect
    @vm_to_connect ||= ps_multiple.vms.find { |vm| vm.id != vm_to_be_connected.id }
  end

  def vm_to_connect_outside
    @vm_to_connect_outside ||= ps_single.vms.first
  end

  def test_connection(to_connect_ip, connecting, should_fail: false, ipv4: true)
    test_version_arg = ipv4 ? "" : "-6"
    connecting.sshable.cmd("nc -zvw 1 #{to_connect_ip} 8080 #{test_version_arg}")
    fail_test "#{connecting.inhost_name} should not be able to connect to #{to_connect_ip} on port 8080" if should_fail
  rescue
    return 0 if should_fail

    fail_test "#{connecting.inhost_name} should be able to connect to #{to_connect_ip} on port 8080"
  end

  def start_listening(ipv4: true)
    vm_to_be_connected.sshable.cmd("sudo systemctl stop listening_ipv#{ipv4 ? "6" : "4"}.service")
    vm_to_be_connected.sshable.cmd("sudo systemctl start listening_ipv#{ipv4 ? "4" : "6"}.service")
  end
end
