# frozen_string_literal: true

class Prog::Vnet::VpcPeeringNexus < Prog::Base
  MAX_PER_PRIVATE_SUBNET = 10
  MAX_PENDING_PER_PROJECT_LOCATION = 5
  PENDING_STATES = %w[creating waiting_for_peer].freeze

  def self.assemble(private_subnet, peer_account_id:, peer_vpc_id:, aws:)
    location = private_subnet.location

    if private_subnet.destroy_set? || private_subnet.destroying_set?
      fail CloverError.new(400, "InvalidRequest", "Private subnet '#{private_subnet.name}' is being deleted")
    end

    DB.transaction do
      private_subnet.project.lock!(:no_key_update)

      peerings = private_subnet.vpc_peerings_dataset
      unless peerings.where(peer_vpc_id:).empty?
        fail Validation::ValidationFailed.new({peer_vpc_id: "This private subnet already has a VPC peering with #{peer_vpc_id}. Delete it first. If you just deleted it, wait until it disappears."})
      end

      if peerings.count >= MAX_PER_PRIVATE_SUBNET
        fail CloverError.new(400, "InvalidRequest", "Private subnet '#{private_subnet.name}' already has #{MAX_PER_PRIVATE_SUBNET} VPC peerings, the maximum")
      end

      subnets = PrivateSubnet.where(project_id: private_subnet.project_id, location_id: private_subnet.location_id).select(:id)
      if VpcPeering.where(private_subnet_id: subnets, state: PENDING_STATES).count >= MAX_PENDING_PER_PROJECT_LOCATION
        fail CloverError.new(400, "InvalidRequest", "This project already has #{MAX_PENDING_PER_PROJECT_LOCATION} VPC peering requests waiting to be accepted in #{location.display_name}. Accept or delete one first.")
      end

      vp = VpcPeering.create(private_subnet_id: private_subnet.id, peer_account_id:, peer_vpc_id:)
      prog = if location.aws?
        unless PrivateSubnetAwsResource.where(vpc_id: peer_vpc_id).empty?
          fail Validation::ValidationFailed.new({peer_vpc_id: "#{peer_vpc_id} is a Ubicloud VPC. Enter the ID of a VPC in your own AWS account."})
        end
        VpcPeeringAwsResource.create_with_id(vp, peer_region: aws.fetch(:peer_region))
        "Vnet::Aws::VpcPeeringNexus"
      else
        fail "VPC peering is not supported in #{location.provider} locations"
      end
      Strand.create_with_id(vp, prog:, label: "start")
    end
  end
end
