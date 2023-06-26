#!/bin/env ruby
# frozen_string_literal: true

require "json"

secrets = JSON.parse($stdin.read)

unless (storage_secrets = secrets["storage"])
  puts "need storage secrets in secrets json"
  exit 1
end

unless (params_path = ARGV.shift)
  puts "expected path to prep.json as argument"
  exit 1
end

params_json = File.read(params_path)
params = JSON.parse(params_json)

unless (vm_name = params["vm_name"])
  puts "need vm_name in parameters json"
  exit 1
end

# "Global Unicast" subnet, i.e. a subnet for exchanging packets with
# the internet.
unless (gua = params["public_ipv6"])
  puts "need public_ipv6 in parameters json"
  exit 1
end

unless (ip4 = params["public_ipv4"])
  puts "need public_ipv4 in parameters json"
  exit 1
end

unless (local_ip4 = params["local_ipv4"])
  puts "need local_ipv4 in parameters json"
  exit 1
end

unless (unix_user = params["unix_user"])
  puts "need unix_user in parameters json"
  exit 1
end

unless (ssh_public_key = params["ssh_public_key"])
  puts "need ssh_public_key in parameters json"
  exit 1
end

unless (private_subnets = params["private_subnets"])
  puts "need private_subnets in parameters json"
  exit 1
end

unless (boot_image = params["boot_image"])
  puts "need boot_image in parameters json"
  exit 1
end

unless (max_vcpus = params["max_vcpus"])
  puts "need max_vcpus in parameters json"
  exit 1
end

unless (cpu_topology = params["cpu_topology"])
  puts "need cpu_topology in parameters json"
  exit 1
end

unless (mem_gib = params["mem_gib"])
  puts "need mem_gib in parameters json"
  exit 1
end

ndp_needed = params.fetch("ndp_needed", false)

unless (storage_volumes = params["storage_volumes"])
  puts "need storage_volumes in parameters json"
  exit 1
end

require "fileutils"
require_relative "../lib/common"
require_relative "../lib/vm_setup"

VmSetup.new(vm_name).prep(unix_user, ssh_public_key, private_subnets, gua, ip4,
  local_ip4, boot_image, max_vcpus, cpu_topology, mem_gib, ndp_needed, storage_volumes,
  storage_secrets)
