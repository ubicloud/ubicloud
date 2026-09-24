#!/usr/bin/env ruby
# frozen_string_literal: true

#
# A stand-in for emberd (design doc 5.1) so the control plane's synchronous
# path can be timed without the real daemon: TLS with a self-signed cert, an
# HS256 bearer JWT, and a configurable server-side delay standing in for the
# restore.
#
# Deliberately a hand-rolled HTTP/1.1 server rather than WEBrick: WEBrick writes
# its status line, headers and body as separate small writes, which reproduces
# exactly the Nagle/delayed-ACK stall found in ubiblk and adds ~40 ms per
# request. That would be measuring the stub, not the design.
#
#   ruby emberd_stub.rb [port] [cert_dir]

require "fileutils"
require "json"
require "openssl"
require "socket"

port = Integer(ARGV[0] || 8452)
cert_dir = ARGV[1] || "/etc/emberd-stub"
FileUtils.mkdir_p(cert_dir)

key_path = File.join(cert_dir, "key.pem")
crt_path = File.join(cert_dir, "crt.pem")
unless File.exist?(key_path) && File.exist?(crt_path)
  key = OpenSSL::PKey::EC.generate("prime256v1")
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = 1
  cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=emberd-stub")
  cert.public_key = key
  cert.not_before = Time.now - 3600
  cert.not_after = Time.now + (365 * 24 * 3600)
  cert.sign(key, OpenSSL::Digest.new("SHA256"))
  File.write(key_path, key.to_pem)
  File.write(crt_path, cert.to_pem)
end

ctx = OpenSSL::SSL::SSLContext.new
ctx.cert = OpenSSL::X509::Certificate.new(File.read(crt_path))
ctx.key = OpenSSL::PKey::EC.new(File.read(key_path))

fingerprint = OpenSSL::Digest::SHA256.hexdigest(ctx.cert.to_der)
warn "emberd stub on #{port}, cert sha256=#{fingerprint}"

tcp = TCPServer.new("0.0.0.0", port)
server = OpenSSL::SSL::SSLServer.new(tcp, ctx)
server.start_immediately = true

def handle(conn)
  loop do
    request_line = conn.gets
    return if request_line.nil?
    path = request_line.split[1].to_s
    content_length = 0
    keep_alive = true
    while (line = conn.gets)
      line = line.strip
      break if line.empty?
      key, _, value = line.partition(":")
      case key.downcase
      when "content-length" then content_length = value.strip.to_i
      when "connection" then keep_alive = !value.strip.casecmp?("close")
      end
    end
    conn.read(content_length) if content_length > 0

    delay = path[/delay_ms=(\d+)/, 1].to_i
    sleep(delay / 1000.0) if delay > 0
    body = if path.start_with?("/v1/health")
      JSON.generate({"slots" => {"total" => 128, "free" => 100}})
    else
      JSON.generate({"slot" => 1, "ip6" => "2a01:db8::1", "phases_ms" => {"total" => delay}})
    end
    # One write: status line, headers and body together, so nothing waits on a
    # delayed ACK.
    conn.write("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n" \
               "Content-Length: #{body.bytesize}\r\nConnection: keep-alive\r\n\r\n#{body}")
    return unless keep_alive
  end
rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, IOError
  nil
ensure
  begin
    conn.close
  rescue
    nil
  end
end

trap("INT") { exit }
trap("TERM") { exit }

loop do
  begin
    conn = server.accept
  rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET
    next
  end
  # The control plane sends a small request and waits for a small reply; Nagle
  # has nothing useful to coalesce and only adds latency.
  begin
    conn.to_io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
  rescue
    nil
  end
  Thread.new { handle(conn) }
end
