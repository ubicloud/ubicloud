#!/bin/env ruby
# frozen_string_literal: true

require "json"

unless (name = ARGV.shift)
  puts "expected name as argument"
  exit 1
end

unless (public_ipv4 = ARGV.shift)
  puts "expected public_ipv4 as argument"
  exit 1
end

unless (local_ipv4 = ARGV.shift)
  puts "expected local_ipv4 as argument"
  exit 1
end

unless (target_ips = ARGV.shift)
  puts "expected target_ips as argument"
  exit 1
end

require "fileutils"
require_relative "../../common/lib/util"
require_relative "../lib/vm_setup"

VmSetup.new(name).prep_loadbalancer(ip4, local_ip4, target_ips)
