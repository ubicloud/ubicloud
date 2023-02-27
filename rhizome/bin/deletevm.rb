#!/bin/env ruby
# frozen_string_literal: true

unless (vm_name = ARGV.shift)
  puts "need vm name as argument"
  exit 1
end

require_relative "../lib/common"

q_vm = vm_name.shellescape
r "deluser --remove-home #{q_vm}"
r "ip netns del #{q_vm}"

# TODO: find routing table entry and delete
