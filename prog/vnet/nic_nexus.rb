# frozen_string_literal: true

class Prog::Vnet::NicNexus < Prog::Base
  subject_is :nic

  def self.assemble(private_subnet_id, name: nil, ipv6_addr: nil, ipv4_addr: nil, exclude_availability_zones: [], availability_zone: nil)
    unless (subnet = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    ubid = Nic.generate_ubid
    id = ubid.to_uuid
    name ||= Nic.ubid_to_name(ubid)

    ipv6_addr ||= subnet.random_private_ipv6.to_s

    DB.transaction do
      prog, ipv4_addr, mac = if subnet.location.aws?
        ["Vnet::Aws::NicNexus", (ipv4_addr || subnet.random_private_ipv4.nth_subnet(32, 4)).to_s, nil]
      else
        ["Vnet::Metal::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, gen_mac]
      end

      Nic.create_with_id(id, private_ipv6: ipv6_addr, private_ipv4: ipv4_addr, mac:, name:, private_subnet_id:)
      Strand.create_with_id(id, prog:, label: "start", stack: [{"exclude_availability_zones" => exclude_availability_zones, "availability_zone" => availability_zone, "ipv4_addr" => ipv4_addr}])
    end
  end

  # Generate a MAC with the "local" (generated, non-manufacturer) bit
  # set and the multicast bit cleared in the first octet.
  #
  # Accuracy here is not a formality: otherwise assigning a ipv6 link
  # local address errors out.
  def self.gen_mac
    ([rand(256) & 0xFE | 0x02] + Array.new(5) { rand(256) }).map {
      "%0.2X" % it
    }.join(":").downcase
  end
end
