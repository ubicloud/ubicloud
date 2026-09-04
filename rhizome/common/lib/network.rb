# frozen_string_literal: true

require "json"

# By reading the mac address from an interface, compute its ipv6
# link local address that it would have if its device state were set
# to up. From RFC 4291 Section 2.5.1 & Appendix A.
def mac_to_ipv6_link_local(mac)
  eui = mac.split(":").map(&:hex)
  eui.insert(3, 0xff, 0xfe)
  eui[0] ^= 0x02

  "fe80::" + eui.each_slice(2).map { |pair|
    pair.map { format("%02x", _1) }.join
  }.join(":")
end

# Generate a MAC with the "local" (generated, non-manufacturer) bit
# set and the multicast bit cleared in the first octet.
#
# Accuracy here is not a formality: otherwise assigning a ipv6 link
# local address errors out.
def gen_mac
  ([rand(256) & 0xFE | 0x02] + Array.new(5) { rand(256) }).map {
    "%0.2X" % _1
  }.join(":").downcase
end

# Returns the device of the first default route among the given route
# listings, which are searched in order.
def default_route_device(*routes_jsons)
  routes = routes_jsons.flat_map { JSON.parse(_1) }
  # A multipath default route carries its devices under nexthops instead,
  # and picking one of them is not something callers can do blindly.
  device = routes.find { |route| route["dst"] == "default" }&.fetch("dev", nil)
  return device if device

  fail "No default route found in #{routes.inspect}"
end
