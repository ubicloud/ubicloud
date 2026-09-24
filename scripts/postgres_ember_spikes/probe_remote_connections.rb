#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Where does the fixed startup cost of a remote stripe source go?
#
# ubiblk dials `connections` fetch connections in a sequential loop
# (src/stripe_source/builder.rs), and each dial is a TCP connect, a TLS-PSK
# handshake and a full metadata fetch. This sweeps the connection count to see
# whether the cost is per-connection and linear.
#
#   ruby probe_remote_connections.rb [counts...]
#
# RUN_TAG=<tag> writes out/probe_conn_<tag>.json instead of the fixed path.
# SERVER_NETNS=<ns> SERVER_ADDRESS=<ip> run the server inside a namespace
# (see rtt_link.sh) and dial it there, for runs with latency on the link.

require_relative "lib/ember"

counts = (ARGV.empty? ? %w[1 2 4 8 16 32] : ARGV).map { Integer(_1) }
pgdata = "#{Spike::IMAGES}/cell-pgdata-18.raw"
HOST_B_ROOT = "/var/storage/detachable-hostb"

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
FileUtils.mkdir_p(HOST_B_ROOT)

# Host A: a volume with a raw stripe source, as a fresh ember volume has.
a = Spike::Volume.new("dvconn")
FileUtils.rm_rf(a.dir)
a.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata, "copy_on_read" => true})

server_address = ENV["SERVER_ADDRESS"] || "127.0.0.1"
srv = Spike::RemoteStripeServer.new(a, port: 5503, netns: ENV["SERVER_NETNS"], check_address: server_address)
srv.start
puts "ubiblk: #{Spike::UBIBLK_DIR}"
puts "remote-stripe-server listening at #{server_address}:5503"
puts "conns  create_ms    start_ms     per_conn_ms"

report = {"ubiblk_dir" => Spike::UBIBLK_DIR, "server_address" => server_address, "server_netns" => ENV["SERVER_NETNS"]}
counts.each do |n|
  b = Spike::Volume.new("dvconn", root: HOST_B_ROOT)
  FileUtils.rm_rf(b.dir)
  source = {"type" => "remote", "address" => "#{server_address}:5503", "autofetch" => false,
            "connections" => n, "psk_identity" => srv.psk_identity,
            "psk_secret" => Base64.decode64(srv.psk)}
  t = Spike.now
  b.create(size_gib: 2, keys_from: a, source:)
  create_ms = Spike.ms(t)
  t = Spike.now
  b.start(timeout: 120)
  start_ms = Spike.ms(t)
  b.stop
  puts format("%-6d %-12.1f %-12.1f %-12.2f", n, create_ms, start_ms, start_ms / n)
  report[n] = {"create_ms" => create_ms, "start_ms" => start_ms}
end

srv.stop
a.stop
Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
out = ENV["RUN_TAG"] ? "probe_conn_#{ENV["RUN_TAG"]}.json" : "probe_remote_connections.json"
File.write(File.join(__dir__, "out", out), JSON.pretty_generate(report))
