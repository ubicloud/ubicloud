# frozen_string_literal: true

require "net/http"
require "uri"

class Prog::Test::FirewallRules < Prog::Test::Base
  subject_is :firewall

  label def start
    vm1.sshable.cmd("sudo yum install -y nc") if vm1.boot_image.include?("almalinux")
    vm2.sshable.cmd("sudo yum install -y nc") if vm2.boot_image.include?("almalinux")
    vm1.sshable.cmd("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/nc -l 8080
' | sudo tee /etc/systemd/system/listening_ipv4.service > /dev/null")

    vm1.sshable.cmd("echo '[Unit]
Description=A lightweight port 8080 listener
After=network.target

[Service]
Type=simple
ExecStart=nc -l 8080 -6
' | sudo tee /etc/systemd/system/listening_ipv6.service > /dev/null")

    vm1.sshable.cmd("sudo systemctl daemon-reload")
    vm1.sshable.cmd("sudo systemctl enable listening_ipv4.service")
    vm1.sshable.cmd("sudo systemctl enable listening_ipv6.service")

    hop_perform_tests_none
  end

  label def perform_tests_none
    update_firewall_rules(config: :perform_tests_none) unless frame["firewalls"] == "none"

    update_stack({
      "firewalls" => "none"
    })

    if firewall.private_subnets.first.update_firewall_rules_set? || firewall.private_subnets.first.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    vm1.sshable.cmd("true")
    vm2.sshable.cmd("true")
    vm1.sshable.cmd("ping -c 2 google.com")
    vm2.sshable.cmd("ping -c 2 google.com")

    vm1.sshable.cmd("sudo systemctl start listening_ipv4.service")
    begin
      vm2.sshable.cmd("nc -zvw 1 #{vm1.ephemeral_net4} 8080")
    rescue
      hop_perform_tests_public_ipv4
    end

    fail_test "#{vm2.inhost_name} should not be able to connect to #{vm1.inhost_name} on port 8080"
  end

  label def perform_tests_public_ipv4
    update_firewall_rules(config: :perform_tests_public_ipv4) unless frame["firewalls"] == "public_ipv4"

    update_stack({
      "firewalls" => "public_ipv4"
    })
    if firewall.private_subnets.first.update_firewall_rules_set? || firewall.private_subnets.first.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    begin
      vm2.sshable.cmd("nc -zvw 1 #{vm1.ephemeral_net4} 8080")
    rescue
      fail_test "#{vm2.inhost_name} should be able to connect to #{vm1.inhost_name} on port 8080"
    end

    begin
      vm_outside.sshable.cmd("nc -zvw 1 #{vm1.ephemeral_net4} 8080")
    rescue
      vm1.sshable.cmd("sudo systemctl stop listening_ipv4.service")
      hop_perform_tests_public_ipv6
    end

    fail_test "#{vm_outside.inhost_name} should not be able to connect to #{vm1.inhost_name} on port 8080"
  end

  label def perform_tests_public_ipv6
    update_firewall_rules(config: :perform_tests_public_ipv6) unless frame["firewalls"] == "public_ipv6"

    update_stack({
      "firewalls" => "public_ipv6"
    })
    if firewall.private_subnets.first.update_firewall_rules_set? || firewall.private_subnets.first.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    vm1.sshable.cmd("sudo systemctl start listening_ipv6.service")
    begin
      vm2.sshable.cmd("nc -zvw 1 #{vm1.ephemeral_net6.nth(2)} 8080 -6")
    rescue
      fail_test "#{vm2.inhost_name} should be able to connect to #{vm1.inhost_name} on port 8080"
    end

    begin
      vm_outside.sshable.cmd("nc -zvw 1 #{vm1.ephemeral_net6.nth(2)} 8080 -6")
    rescue
      vm1.sshable.cmd("sudo systemctl stop listening_ipv6.service")
      hop_perform_tests_private_ipv4
    end

    fail_test "#{vm_outside.inhost_name} should not be able to connect to #{vm1.inhost_name} on port 8080"
  end

  label def perform_tests_private_ipv4
    update_firewall_rules(config: :perform_tests_private_ipv4) unless frame["firewalls"] == "private_ipv4"

    update_stack({
      "firewalls" => "private_ipv4"
    })
    if firewall.private_subnets.first.update_firewall_rules_set? || firewall.private_subnets.first.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    vm1.sshable.cmd("sudo systemctl start listening_ipv4.service")
    begin
      vm2.sshable.cmd("nc -zvw 1 #{vm1.nics.first.private_ipv4.nth(0)} 8080")
    rescue
      fail_test "#{vm2.inhost_name} should be able to connect to #{vm1.inhost_name} on port 8080"
    end
    vm1.sshable.cmd("sudo systemctl stop listening_ipv4.service")
    hop_perform_tests_private_ipv6
  end

  label def perform_tests_private_ipv6
    update_firewall_rules(config: :perform_tests_private_ipv6) unless frame["firewalls"] == "private_ipv6"

    update_stack({
      "firewalls" => "private_ipv6"
    })
    if firewall.private_subnets.first.update_firewall_rules_set? || firewall.private_subnets.first.vms.any? { |vm| vm.update_firewall_rules_set? }
      nap 5
    end

    vm1.sshable.cmd("sudo systemctl start listening_ipv6.service")
    begin
      vm2.sshable.cmd("nc -zvw 1 #{vm1.nics.first.private_ipv6.nth(2)} 8080 -6")
    rescue
      fail_test "#{vm2.inhost_name} should be able to connect to #{vm1.inhost_name} on port 8080"
    end
    vm1.sshable.cmd("sudo systemctl stop listening_ipv6.service")
    hop_finish
  end

  label def finish
    pop "Verified Firewall Rules!"
  end

  label def failed
    nap 15
  end

  def update_firewall_rules(config: nil)
    uri = URI("https://api.ipify.org")
    my_ip = Net::HTTP.get(uri)
    firewall_rules = [
      {cidr: "#{my_ip}/32", port_range: Sequel.pg_range(22..22)}
    ]
    firewall_rules << case config
    when :perform_tests_none
      nil
    when :perform_tests_public_ipv4
      {cidr: vm2.ephemeral_net4.to_s, port_range: Sequel.pg_range(8080..8080)}
    when :perform_tests_public_ipv6
      {cidr: vm2.ephemeral_net6.nth(2).to_s, port_range: Sequel.pg_range(8080..8080)}
    when :perform_tests_private_ipv4
      {cidr: vm2.nics.first.private_ipv4.to_s, port_range: Sequel.pg_range(8080..8080)}
    when :perform_tests_private_ipv6
      {cidr: vm2.nics.first.private_ipv6.nth(2).to_s, port_range: Sequel.pg_range(8080..8080)}
    else
      raise "Unknown config: #{config}"
    end

    firewall.replace_firewall_rules(firewall_rules.compact)
  end

  def vm1
    @vm1 ||= firewall.private_subnets.first.vms.first
  end

  def vm2
    @vm2 ||= firewall.private_subnets.first.vms.last
  end

  def vm_outside
    @vm_outside ||= PrivateSubnet.all.find { |ps| ps.id != vm1.private_subnets.first.id }.vms.first
  end
end
