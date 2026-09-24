#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Gateway under test, Ruby version. Same shape as gateway.go: terminate the
# client's TLS, open a second TLS session upstream, splice both ways, one
# thread per direction per connection (the natural MRI structure).

require "openssl"
require "socket"

listen_port = Integer(ARGV[0].split(":").last)
up_host, up_port = ARGV[1].split(":")
up_port = Integer(up_port)

ctx = OpenSSL::SSL::SSLContext.new
ctx.cert = OpenSSL::X509::Certificate.new(File.read("cert.pem"))
ctx.key = OpenSSL::PKey.read(File.read("key.pem"))

up_ctx = OpenSSL::SSL::SSLContext.new
up_ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE

tcp = TCPServer.new("0.0.0.0", listen_port)
server = OpenSSL::SSL::SSLServer.new(tcp, ctx)
server.start_immediately = true
warn "ruby gateway on #{listen_port} -> #{up_host}:#{up_port}"

def splice(from, to)
  buf = +""
  loop do
    from.readpartial(65_536, buf)
    to.write(buf)
  end
rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
  nil
end

loop do
  begin
    client = server.accept
  rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET
    next
  end
  Thread.new(client) do |c|
    up = nil
    begin
      raw = TCPSocket.new(up_host, up_port)
      raw.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      up = OpenSSL::SSL::SSLSocket.new(raw, up_ctx)
      up.sync_close = true
      up.connect
      t = Thread.new { splice(up, c) }
      splice(c, up)
      t.kill
    rescue => e
      warn "conn: #{e.class}" if ENV["VERBOSE"]
    ensure
      begin
        up&.close
      rescue
        nil
      end
      begin
        c.close
      rescue
        nil
      end
    end
  end
end
