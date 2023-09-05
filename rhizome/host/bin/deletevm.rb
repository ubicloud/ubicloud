#!/bin/env ruby
# frozen_string_literal: true

unless (vm_name = ARGV.shift)
  puts "need vm name as argument"
  exit 1
end

require_relative "../../common/lib/util"
require_relative "../lib/vm_setup"

VmSetup.new(vm_name).purge
