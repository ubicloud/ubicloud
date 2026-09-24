#!/usr/bin/env ruby
# frozen_string_literal: true

# Where does the ~1.3 s of ubiblk startup against a remote stripe source go?
require_relative "lib/ember"

pgdata = "#{Spike::IMAGES}/cell-pgdata-18.raw"
Spike.sh("bash", File.join(__dir__, "cleanup.sh"), check: false)
FileUtils.mkdir_p("/var/storage/detachable-hostb")

a = Spike::Volume.new("dvprobe")
FileUtils.rm_rf(a.dir)
t = Spike.now
a.create(size_gib: 2, source: {"type" => "raw", "image_path" => pgdata, "copy_on_read" => true})
puts "raw-source volume create:  #{Spike.ms(t)} ms"
t = Spike.now
a.start
puts "raw-source backend start:  #{Spike.ms(t)} ms"
a.stop

srv = Spike::RemoteStripeServer.new(a, port: 5502)
t = Spike.now
srv.start
puts "remote-stripe-server up:   #{Spike.ms(t)} ms"

b = Spike::Volume.new("dvprobe", root: "/var/storage/detachable-hostb")
FileUtils.rm_rf(b.dir)
t = Spike.now
b.create(size_gib: 2, keys_from: a,
  source: {"type" => "remote", "address" => "127.0.0.1:5502", "autofetch" => false,
           "psk_identity" => srv.psk_identity, "psk_secret" => Base64.decode64(srv.psk)})
puts "remote-source create:      #{Spike.ms(t)} ms  (init-metadata)"
t = Spike.now
b.start
puts "remote-source start:       #{Spike.ms(t)} ms  (to vhost.sock)"
t = Spike.now
puts "first status rpc:          #{b.rpc("status").inspect} in #{Spike.ms(t)} ms"
b.stop

# Restarting an already-initialised remote-source volume is the resume path.
t = Spike.now
b.start
puts "remote-source restart:     #{Spike.ms(t)} ms"
b.stop
srv.stop
puts "--- host B ubiblk log ---"
puts File.read("#{b.dir}/ubiblk.log").lines.last(25).join
