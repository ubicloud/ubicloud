#!/bin/env ruby
# frozen_string_literal: true

unless (vm_name = ARGV.shift)
  puts "need vm name as argument"
  exit 1
end

# "Global Unicast" subnet, i.e. a subnet for exchanging packets with
# the internet.
unless (gua = ARGV.shift)
  puts "need global unicast subnet as argument"
  exit 1
end

require "fileutils"
require_relative "../lib/common"
require_relative "../lib/vm_setup"

VmSetup.new(vm_name).prep(gua)
