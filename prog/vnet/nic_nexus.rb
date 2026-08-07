# frozen_string_literal: true

class Prog::Vnet::NicNexus < Prog::Base
  subject_is :nic

  def self.assemble(private_subnet_id, name: nil, ipv6_addr: nil, ipv4_addr: nil, exclude_availability_zones: [], availability_zone: nil, is_management: false, use_eip: true)
    unless (subnet = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    ubid = Nic.generate_ubid
    id = ubid.to_uuid
    name ||= Nic.ubid_to_name(ubid)

    ipv6_addr ||= subnet.random_private_ipv6.to_s

    DB.transaction do
      prog, ipv4, mac, state, aws_subnet_id = if subnet.location.aws?
        aws_subnet, aws_ipv4 = if ipv4_addr
          [select_aws_subnet(subnet, availability_zone, exclude_availability_zones), ipv4_addr]
        else
          select_aws_subnet_and_ipv4(subnet, availability_zone, exclude_availability_zones)
        end
        ["Vnet::Aws::NicNexus", aws_ipv4.to_s, nil, "active", aws_subnet&.id]
      elsif subnet.location.gcp?
        ["Vnet::Gcp::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, nil, "active", nil]
      else
        ["Vnet::Metal::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, gen_mac, "initializing", nil]
      end

      Nic.create_with_id(id, private_ipv6: ipv6_addr, private_ipv4: ipv4, mac:, name:, private_subnet_id:, state:, is_management:)
      label = (subnet.location_id == Location::GITHUB_RUNNERS_ID) ? "wait" : "start"
      Strand.create_with_id(id, prog:, label:, stack: [{"exclude_availability_zones" => exclude_availability_zones, "availability_zone" => availability_zone, "ipv4_addr" => ipv4, "aws_subnet_id" => aws_subnet_id, "use_eip" => use_eip}])
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

  def self.select_aws_subnet(subnet, availability_zone, exclude_availability_zones)
    aws_subnet_candidates(subnet, availability_zone, exclude_availability_zones).first
  end

  # Order the per-AZ AWS subnets by allocation preference: subnets with a
  # free IP first, the preferred AZ before others, excluded AZs last, ties
  # broken randomly. Full subnets still appear at the end so callers that
  # only need an AZ choice always get one.
  def self.aws_subnet_candidates(subnet, availability_zone, exclude_availability_zones)
    ps_aws_resource = subnet.private_subnet_aws_resource
    return [] unless ps_aws_resource

    nic_counts = subnet.nics_dataset
      .join(:aws_subnet, private_subnet_aws_resource_id: ps_aws_resource.id)
      .where(Sequel.lit("nic.private_ipv4 <<= aws_subnet.ipv4_cidr"))
      .group_and_count(Sequel[:aws_subnet][:id])
      .to_hash(:id, :count)

    ps_aws_resource.aws_subnets.sort_by do |aws_subnet|
      full = nic_counts[aws_subnet.id].to_i >= aws_subnet_capacity(aws_subnet)
      az = aws_subnet.az_suffix
      [full ? 1 : 0, (az == availability_zone) ? 0 : 1, exclude_availability_zones.include?(az) ? 1 : 0, rand]
    end
  end

  # AWS reserves the first four (network, VPC router, DNS, future use)
  # and the last (broadcast) addresses of every subnet.
  def self.aws_subnet_capacity(aws_subnet)
    cidr = NetAddr::IPv4Net.parse(aws_subnet.ipv4_cidr.to_s)
    2**(32 - cidr.netmask.prefix_len) - 5
  end

  def self.select_aws_subnet_and_ipv4(subnet, availability_zone, exclude_availability_zones)
    candidates = aws_subnet_candidates(subnet, availability_zone, exclude_availability_zones)
    return [nil, subnet.random_private_ipv4] if candidates.empty?

    taken = subnet.nics_dataset.all.map { it.private_ipv4.network.to_s }.to_set
    candidates.each do |aws_subnet|
      if (ipv4 = random_free_ipv4(aws_subnet, taken))
        return [aws_subnet, ipv4]
      end
    end
    fail "No free private IPv4 address in any AZ subnet of #{subnet.ubid}"
  end

  def self.random_free_ipv4(aws_subnet, taken)
    cidr = NetAddr::IPv4Net.parse(aws_subnet.ipv4_cidr.to_s)
    offset = (4..(2**(32 - cidr.netmask.prefix_len) - 2)).to_a.shuffle.find { !taken.include?(cidr.nth(it).to_s) }
    "#{cidr.nth(offset)}/32" if offset
  end
end
