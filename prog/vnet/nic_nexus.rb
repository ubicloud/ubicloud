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
      prog, ipv4_addr, mac, state, aws_subnet_id = if subnet.location.aws?
        aws_subnet = select_aws_subnet(subnet, availability_zone, exclude_availability_zones)
        ["Vnet::Aws::NicNexus", ipv4_addr&.to_s, nil, ipv4_addr ? "active" : "creating", aws_subnet&.id]
      elsif subnet.location.gcp?
        ["Vnet::Gcp::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, nil, "active", nil]
      else
        ["Vnet::Metal::NicNexus", (ipv4_addr || subnet.random_private_ipv4).to_s, gen_mac, "initializing", nil]
      end

      Nic.create_with_id(id, private_ipv6: ipv6_addr, private_ipv4: ipv4_addr, mac:, name:, private_subnet_id:, state:, is_management:)
      label = (subnet.location_id == Location::GITHUB_RUNNERS_ID) ? "wait" : "start"
      Strand.create_with_id(id, prog:, label:, stack: [{"exclude_availability_zones" => exclude_availability_zones, "availability_zone" => availability_zone, "ipv4_addr" => ipv4_addr, "aws_subnet_id" => aws_subnet_id, "use_eip" => use_eip}])
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
      subnet.location.location_azs_dataset.where(az: exclude_availability_zones).select_map(:id)
    end

    # Try to find subnet for preferred AZ
    if availability_zone
      location_az = subnet.location.location_azs_dataset.first(az: availability_zone)
      if location_az
        aws_subnet = AwsSubnet.first(
          private_subnet_aws_resource_id: ps_aws_resource.id,
          location_aws_az_id: location_az.id,
        )
        return aws_subnet if aws_subnet
      end
    end

    # Fallback to any available subnet
    base_ds = AwsSubnet.where(private_subnet_aws_resource_id: ps_aws_resource.id)
    ds = excluded_az_ids.empty? ? base_ds : base_ds.exclude(location_aws_az_id: excluded_az_ids)
    ds.order_by(Sequel.function(:random)).first || base_ds.order_by(Sequel.function(:random)).first
  end
end
