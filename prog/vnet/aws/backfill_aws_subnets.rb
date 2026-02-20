# frozen_string_literal: true

require "aws-sdk-ec2"

class Prog::Vnet::Aws::BackfillAwsSubnets < Prog::Base
  subject_is :private_subnet

  def self.assemble(private_subnet_id)
    unless (ps = PrivateSubnet[private_subnet_id])
      fail "No existing private subnet"
    end

    unless ps.location.aws?
      fail "Private subnet is not in an AWS location"
    end

    unless (ps_aws_resource = ps.private_subnet_aws_resource)
      fail "Private subnet has no AWS resource"
    end

    unless ps_aws_resource.vpc_id
      fail "Private subnet AWS resource has no VPC ID"
    end

    if ps_aws_resource.aws_subnets.any?
      fail "Private subnet already has AwsSubnet records"
    end

    Strand.create(
      prog: "Vnet::Aws::BackfillAwsSubnets",
      label: "start",
      stack: [{"subject_id" => private_subnet_id}]
    )
  end

  label def start
    if old_subnet?
      hop_backfill_old_subnet
    else
      hop_fetch_existing_subnets
    end
  end

  label def backfill_old_subnet
    subnets = client.describe_subnets({
      filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]
    }).subnets

    fail "No subnets found in VPC #{private_subnet_aws_resource.vpc_id}" if subnets.empty?

    used_subnet_ids = private_subnet.nics.map { it.nic_aws_resource.subnet_id }.compact.uniq
    subnets = subnets.select { |subnet| used_subnet_ids.include?(subnet.subnet_id) }

    # this assumes there is only non-ha postgres resources
    subnet = subnets.min_by(&:cidr_block)
    az_suffix = subnet.availability_zone.delete_prefix(location.name)
    location_aws_az = find_location_aws_az(az_suffix)

    AwsSubnet.create(
      private_subnet_aws_resource_id: private_subnet_aws_resource.id,
      location_aws_az_id: location_aws_az.id,
      ipv4_cidr: subnet.cidr_block,
      ipv6_cidr: subnet.ipv_6_cidr_block_association_set.first.ipv_6_cidr_block,
      subnet_id: subnet.subnet_id
    )

    hop_link_nics
  end

  label def fetch_existing_subnets
    subnets = client.describe_subnets({
      filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]
    }).subnets

    # Ensure AZ records exist
    location.azs

    used_subnet_ids = private_subnet.nics.map { it.nic_aws_resource.subnet_id }.compact.uniq
    subnets = subnets.select { |subnet| used_subnet_ids.include?(subnet.subnet_id) }

    # Group subnets by AZ suffix, keep only the first per AZ
    # this assumes there is only non-ha postgres resources
    az_subnet_map = {}
    subnets.sort_by(&:cidr_block).each do |subnet|
      az_suffix = subnet.availability_zone.delete_prefix(location.name)
      az_subnet_map[az_suffix] ||= {
        "subnet_id" => subnet.subnet_id,
        "cidr_block" => subnet.cidr_block,
        "ipv6_cidr" => subnet.ipv_6_cidr_block_association_set.first.ipv_6_cidr_block
      }
    end

    update_stack({"az_subnet_map" => az_subnet_map})
    hop_create_records
  end

  label def create_records
    azs = location.azs
    az_subnet_map = frame["az_subnet_map"]
    vpc_ipv4 = private_subnet.net4
    ipv4_prefix = 24

    azs.each_with_index do |az, idx|
      existing = az_subnet_map[az.az]
      ipv4_cidr = existing ? existing["cidr_block"] : vpc_ipv4.nth_subnet(ipv4_prefix, idx).to_s

      AwsSubnet.create(
        private_subnet_aws_resource_id: private_subnet_aws_resource.id,
        location_aws_az_id: az.id,
        ipv4_cidr:,
        ipv6_cidr: existing&.dig("ipv6_cidr"),
        subnet_id: existing&.dig("subnet_id")
      )
    end

    hop_link_nics
  end

  label def link_nics
    aws_subnets_by_az = private_subnet_aws_resource.reload.aws_subnets.each_with_object({}) do |aws_subnet, hash|
      hash[aws_subnet.location_aws_az.az] = aws_subnet
    end

    private_subnet.nics.each do |nic|
      next unless nic.nic_aws_resource
      next if nic.nic_aws_resource.aws_subnet_id

      subnet_az = nic.nic_aws_resource.subnet_az
      next unless subnet_az

      # subnet_az may be full name ("us-west-2a") or just suffix ("a")
      az_suffix = subnet_az.delete_prefix(location.name)
      aws_subnet = aws_subnets_by_az[az_suffix]
      next unless aws_subnet

      nic.nic_aws_resource.update(aws_subnet_id: aws_subnet.id, subnet_az: az_suffix)
    end

    if old_subnet?
      hop_finish
    else
      hop_create_missing_az_subnets
    end
  end

  label def create_missing_az_subnets
    vpc = client.describe_vpcs({
      filters: [{name: "vpc-id", values: [private_subnet_aws_resource.vpc_id]}]
    }).vpcs[0]

    vpc_ipv6 = NetAddr::IPv6Net.parse(vpc.ipv_6_cidr_block_association_set[0].ipv_6_cidr_block)

    private_subnet_aws_resource.reload.aws_subnets.each_with_index do |aws_subnet, idx|
      next if aws_subnet.subnet_id

      ipv6_cidr = vpc_ipv6.nth_subnet(64, idx)
      full_az = location.name + aws_subnet.location_aws_az.az

      subnet = client.create_subnet({
        vpc_id: private_subnet_aws_resource.vpc_id,
        cidr_block: aws_subnet.ipv4_cidr.to_s,
        ipv_6_cidr_block: ipv6_cidr.to_s,
        availability_zone: full_az,
        tag_specifications: Util.aws_tag_specifications("subnet", "#{private_subnet.name}-#{aws_subnet.location_aws_az.az}")
      }).subnet

      client.modify_subnet_attribute({
        subnet_id: subnet.subnet_id,
        assign_ipv_6_address_on_creation: {value: true}
      })

      # Persist immediately so we skip on retry if associate_route_table fails
      aws_subnet.update(subnet_id: subnet.subnet_id, ipv6_cidr: ipv6_cidr.to_s)
    end

    hop_associate_route_tables
  end

  label def associate_route_tables
    private_subnet_aws_resource.reload.aws_subnets.each do |aws_subnet|
      client.associate_route_table({
        route_table_id: private_subnet_aws_resource.route_table_id,
        subnet_id: aws_subnet.subnet_id
      })
    rescue Aws::EC2::Errors::ResourceAlreadyAssociated
    end

    hop_finish
  end

  label def finish
    pop "AwsSubnet records backfilled successfully"
  end

  def location
    @location ||= private_subnet.location
  end

  def client
    @client ||= location.location_credential.client
  end

  def private_subnet_aws_resource
    @private_subnet_aws_resource ||= private_subnet.private_subnet_aws_resource
  end

  private

  def old_subnet?
    private_subnet.net4.netmask.prefix_len == PrivateSubnet::DEFAULT_SUBNET_PREFIX_LEN
  end

  def find_location_aws_az(az_suffix)
    location_aws_az = location.location_aws_azs_dataset.where(az: az_suffix).first
    unless location_aws_az
      location.azs
      location_aws_az = location.location_aws_azs_dataset.where(az: az_suffix).first
      fail "Could not find LocationAwsAz for AZ #{az_suffix}" unless location_aws_az
    end
    location_aws_az
  end
end
