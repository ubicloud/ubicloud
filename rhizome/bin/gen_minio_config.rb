#!/bin/env ruby
# frozen_string_literal: true

unless (minio_node_name = ARGV.shift)
  puts "need minio node name as argument"
  exit 1
end


require_relative "../lib/common"
require_relative "../lib/minio_setup"

MinioSetup.new().configure(minio_node_name)
