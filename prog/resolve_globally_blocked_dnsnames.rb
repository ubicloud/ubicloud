# frozen_string_literal: true

require "socket"
require "open-uri"
require "net/http"
class Prog::ResolveGloballyBlockedDnsnames < Prog::Base
  label def wait
    GloballyBlockedDnsname.each do |globally_blocked_dnsname|
      dns_name = globally_blocked_dnsname.dns_name

      begin
        addr_info = Socket.getaddrinfo(dns_name, nil)
      rescue SocketError
        Clog.emit("Failed to resolve blocked dns name") { {dns_name: dns_name} }
        next
      end

      ip_list = addr_info.map do |info|
        info[3]
      end.uniq

      globally_blocked_dnsname.update(ip_list:, last_check_at: Time.now)
    end

    nap 60 * 60
  end
end
