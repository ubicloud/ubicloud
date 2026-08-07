# frozen_string_literal: true

class Prog::Vnet::NicNexus < Prog::Base
  subject_is :nic

  def self.assemble(private_subnet_id, name: nil, ipv6_addr: nil, ipv4_addr: nil, exclude_availability_zones: [], availability_zone: nil, is_management: false, use_eip: true, use_per_nic_security_group: false)
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
        aws_assigns_ipv4 = !use_eip && ipv4_addr.nil?
        ipv4 = ipv4_addr || allocate_ipv4_from_aws_subnet(subnet, aws_subnet) unless aws_assigns_ipv4
        ["Vnet::Aws::NicNexus", ipv4&.to_s, nil, aws_assigns_ipv4 ? "creating" : "active", aws_subnet&.id]
      elsif subnet.location.gcp?
        ["Vnet::Gcp::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, nil, "active", nil]
      else
        ["Vnet::Metal::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, gen_mac, "initializing", nil]
      end

      Nic.create_with_id(id, private_ipv6: ipv6_addr, private_ipv4: ipv4_addr, mac:, name:, private_subnet_id:, state:, is_management:)
      label = (subnet.location_id == Location::GITHUB_RUNNERS_ID) ? "wait" : "start"
      Strand.create_with_id(id, prog:, label:, stack: [{"exclude_availability_zones" => exclude_availability_zones, "availability_zone" => availability_zone, "ipv4_addr" => ipv4_addr, "aws_subnet_id" => aws_subnet_id, "use_eip" => use_eip, "use_per_nic_security_group" => use_per_nic_security_group}])
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

    excluded_az_ids = subnet.location.location_azs_dataset.where(az: exclude_availability_zones).select_map(:id)
    aws_subnets = AwsSubnet.where(private_subnet_aws_resource_id: ps_aws_resource.id).all
    candidates = aws_subnets.reject { excluded_az_ids.include?(it.location_aws_az_id) }
    candidates = aws_subnets if candidates.empty?

    if availability_zone
      location_az = subnet.location.location_azs_dataset.first(az: availability_zone)
      aws_subnet = candidates.find { it.location_aws_az_id == location_az&.id }
      return aws_subnet if aws_subnet&.available_ipv4_count&.positive?
    end

    candidates.max_by { [it.available_ipv4_count, rand] }
  end

  def self.allocate_ipv4_from_aws_subnet(subnet, aws_subnet)
    return subnet.random_private_ipv4 unless aws_subnet

    subnet_cidr = NetAddr::IPv4Net.parse(aws_subnet.ipv4_cidr.to_s)
    taken = Set.new(subnet.nics_dataset.exclude(private_ipv4: nil).select_map(:private_ipv4)) { it.network.to_s }

    Prog::Vnet::SubnetNexus.until_random_ip("Could not find random IPv4 in AWS subnet after 1000 iterations") do
      # AWS reserves first 4 and last 1 IPs in each subnet
      total_hosts = 2**(32 - subnet_cidr.netmask.prefix_len) - 5
      random_offset = SecureRandom.random_number(total_hosts) + 4

      addr = subnet_cidr.nth(random_offset)

      next if taken.include?(addr.to_s)

      "#{addr}/32"
    end
  end
end
