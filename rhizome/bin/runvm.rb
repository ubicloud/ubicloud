#!/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/common"
require_relative "../lib/vm_path"

unless (vm_name = ARGV.shift)
  puts "need vm name as argument"
  exit 1
end

vp = VmPath.new(vm_name)
q_vm = vm_name.shellescape
q_guest_mac = vp.read_guest_mac.strip.shellescape
exec <<EOS
ip netns exec #{q_vm} sudo -u #{q_vm} -i -- /opt/cloud-hypervisor/v30.0/cloud-hypervisor --kernel /opt/fw/v0.4.2/hypervisor-fw --disk path=boot.raw --disk path=ubuntu-cloudinit.img --console file=console.log --cpus boot=4 --memory size=1024M --net "mac="#{q_guest_mac.shellescape}",tap=tap"#{q_vm.shellescape}",ip=,mask="
EOS
