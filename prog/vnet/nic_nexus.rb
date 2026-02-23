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
      prog, ipv4_addr, mac, state, aws_subnet_id = if subnet.location.aws?
        aws_subnet = select_aws_subnet(subnet, availability_zone, exclude_availability_zones)
        ipv4 = ipv4_addr || allocate_ipv4_from_aws_subnet(subnet, aws_subnet)
        ["Vnet::Aws::NicNexus", ipv4.to_s, nil, "active", aws_subnet&.id]
      elsif subnet.location.gcp?
        ["Vnet::Gcp::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, nil, "active", nil]
      else
        ["Vnet::Metal::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, gen_mac, "initializing", nil]
      end

      Nic.create_with_id(id, private_ipv6: ipv6_addr, private_ipv4: ipv4_addr, mac:, name:, private_subnet_id:, state:)
      label = (subnet.location_id == Location::GITHUB_RUNNERS_ID) ? "wait" : "start"
      Strand.create_with_id(id, prog:, label:, stack: [{"exclude_availability_zones" => exclude_availability_zones, "availability_zone" => availability_zone, "ipv4_addr" => ipv4_addr, "aws_subnet_id" => aws_subnet_id}])
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
    ps_aws_resource = subnet.private_subnet_aws_resource
    return unless ps_aws_resource

    excluded_az_ids = if exclude_availability_zones.empty?
      []
    else
      subnet.location.location_aws_azs_dataset.where(az: exclude_availability_zones).select_map(:id)
    end

    # Try to find subnet for preferred AZ
    if availability_zone
      location_aws_az = subnet.location.location_aws_azs_dataset.first(az: availability_zone)
      if location_aws_az
        aws_subnet = AwsSubnet.first(
          private_subnet_aws_resource_id: ps_aws_resource.id,
          location_aws_az_id: location_aws_az.id
        )
        return aws_subnet if aws_subnet
      end
    end

    # Fallback to any available subnet
    AwsSubnet
      .where(private_subnet_aws_resource_id: ps_aws_resource.id)
      .exclude(location_aws_az_id: excluded_az_ids)
      .order_by(Sequel.function(:random))
      .first
  end

  def self.allocate_ipv4_from_aws_subnet(subnet, aws_subnet)
    return subnet.random_private_ipv4 unless aws_subnet

    subnet_cidr = NetAddr::IPv4Net.parse(aws_subnet.ipv4_cidr.to_s)

    Prog::Vnet::SubnetNexus.until_random_ip("Could not find random IPv4 in AWS subnet after 1000 iterations") do
      # AWS reserves first 4 and last 1 IPs in each subnet
      total_hosts = 2**(32 - subnet_cidr.netmask.prefix_len) - 5
      random_offset = SecureRandom.random_number(total_hosts) + 4

      addr = subnet_cidr.nth(random_offset)

      # Check no existing NIC uses this IP
      next if subnet.nics.any? { |n| n.private_ipv4.network.to_s == addr.to_s }

      "#{addr}/32"
    end
  end
end
