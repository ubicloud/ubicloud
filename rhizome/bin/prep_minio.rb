#!/bin/env ruby
# frozen_string_literal: true

unless (minio_cluster_name = ARGV.shift)
  puts "need minio cluster name as argument"
  exit 1
end

require_relative "../lib/common"
require_relative "../lib/minio_setup"

MinioSetup.new.setup
