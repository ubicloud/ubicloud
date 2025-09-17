#!/bin/env ruby
# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"
require "json"

unless (additional_ip_addresses = ARGV.shift)
  puts "additional IP addresses didn't get passed"
  additional_ip_addresses = "[]"
end

# setup blocking unused ip addresses
NFTABLES_PATH = "/etc/nftables.d/0.conf"
FileUtils.mkdir_p("/etc/nftables.d")
FileUtils.touch(NFTABLES_PATH)
ip_ranges_to_block = JSON.parse(additional_ip_addresses)

safe_write_to_file(NFTABLES_PATH, <<SETUP_ADDITIONAL_IP_BLOCKING)
#!/usr/sbin/nft -f
table inet drop_unused_ip_packets;
delete table inet drop_unused_ip_packets;
table inet drop_unused_ip_packets {
  set allowed_ipv4_addresses {
    type ipv4_addr;
  }

  set blocked_ipv4_addresses {
    type ipv4_addr;
    flags interval;
#{"elements = {#{ip_ranges_to_block.join(",")}}" unless ip_ranges_to_block.empty?}
  }

  chain prerouting {
    type filter hook prerouting priority 0; policy accept;
    ip daddr @allowed_ipv4_addresses accept
    ip daddr @blocked_ipv4_addresses drop
  }
}
SETUP_ADDITIONAL_IP_BLOCKING

File.open("/etc/nftables.conf", File::APPEND | File::RDWR) do |f|
  # Necessary to keep this idempotent
  break if f.each_line.any? { |line| line.include?("include \"/etc/nftables.d/*.conf") }

  f.write("include \"/etc/nftables.d/*.conf\"\n")
end

r "systemctl enable nftables"
r "systemctl start nftables"
