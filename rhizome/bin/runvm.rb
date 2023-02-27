#!/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/common"

unless (vm_name = ARGV.shift)
  puts "need vm name as argument"
  exit 1
end

q_vm = vm_name.shellescape
q_guest_mac = File.read("/home/#{vm_name}/guest_mac").strip.shellescape
exec <<EOS
ip netns exec #{q_vm} sudo -u #{q_vm} -i -- /opt/cloud-hypervisor/v30.0/cloud-hypervisor --kernel /opt/fw/v0.4.2/hypervisor-fw --disk path=boot.raw --disk path=ubuntu-cloudinit.img --cpus boot=4 --memory size=1024M --net "mac="#{q_guest_mac.shellescape}",tap=tap"#{q_vm.shellescape}",ip=,mask="
EOS
