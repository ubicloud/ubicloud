#!/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/common"

unless (vm_name = ARGV.shift)
  puts "need vm name as argument"
  exit 1
end

q_vm = vm_name.shellescape

exec <<EOS
ip netns exec #{q_vm} sudo -u #{q_vm} -i bash -c 'exec /opt/cloud-hypervisor/target/release/cloud-hypervisor --kernel /opt/cloud-hypervisor/hypervisor-fw --disk path=focal-server-cloudimg-amd64.raw --disk path=ubuntu-cloudinit.img --cpus boot=4 --memory size=1024M --net "mac=$(cat guest_mac),tap=tap#{q_vm.shellescape},ip=,mask="'
EOS
