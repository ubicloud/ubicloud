# frozen_string_literal: true

# By reading the mac address from an interface, compute its ipv6
# link local address that it would have if its device state were set
# to up.
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
