#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Is the ~84 ms per remote-stripe connection a Nagle / delayed-ACK stall?
#
# Captures loopback traffic for a single connection's handshake and prints the
# inter-packet gaps. Two ~40 ms gaps would mean small writes are sitting in the
# sender's Nagle queue waiting for the peer's delayed ACK.

require_relative "lib/ember"

PORT = 5504
pgdata = "#{Spike::IMAGES}/cell-pgdata-18.raw"
HOST_B_ROOT = "/var/storage/detachable-hostb"
PCAP = "/tmp/stripe-handshake.pcap"

Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
FileUtils.mkdir_p(HOST_B_ROOT)

a = Spike::Volume.new("dvnagle")
FileUtils.rm_rf(a.dir)
a.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata, "copy_on_read" => true})
srv = Spike::RemoteStripeServer.new(a, port: PORT)
srv.start

FileUtils.rm_f(PCAP)
tcpdump = Process.spawn("tcpdump", "-i", "lo", "-w", PCAP, "-U", "port", PORT.to_s,
  out: "/dev/null", err: "/dev/null")
sleep 1

b = Spike::Volume.new("dvnagle", root: HOST_B_ROOT)
FileUtils.rm_rf(b.dir)
t = Spike.now
b.create(size_gib: 2, keys_from: a,
  source: {"type" => "remote", "address" => "127.0.0.1:#{PORT}", "autofetch" => false,
           "connections" => 1, "psk_identity" => srv.psk_identity,
           "psk_secret" => Base64.decode64(srv.psk)})
puts "single connection took #{Spike.ms(t)} ms"

sleep 1
Process.kill("TERM", tcpdump)
Process.wait(tcpdump)
srv.stop
a.stop
b.stop

puts "\npacket timeline (relative ms, gap ms):"
lines = Spike.sh("tcpdump", "-r", PCAP, "-n", "-tt", "--", check: false).lines
prev = nil
first = nil
lines.each do |line|
  ts = line.split.first.to_f
  next if ts.zero?
  first ||= ts
  gap = prev ? (ts - prev) * 1000 : 0
  flag = (gap > 20) ? "  <-- STALL" : ""
  puts format("  %8.2f  +%7.2f  %s%s", (ts - first) * 1000, gap,
    line.split(":", 2).last.to_s.strip[0, 90], flag)
  prev = ts
end
Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
