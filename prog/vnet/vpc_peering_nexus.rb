# frozen_string_literal: true

class Prog::Vnet::VpcPeeringNexus < Prog::Base
  MAX_PER_PRIVATE_SUBNET = 10
  MAX_PENDING_PER_PROJECT_LOCATION = 5
  MAX_PENDING_PER_LOCATION = 20
  PENDING_STATES = %w[creating waiting_for_peer].freeze

  def self.assemble(private_subnet, peer_account_id:, peer_vpc_id:, aws: nil)
    location = private_subnet.location

    if private_subnet.destroy_set? || private_subnet.destroying_set?
      fail CloverError.new(400, "InvalidRequest", "Private subnet '#{private_subnet.name}' is being deleted")
    end

    if location.aws? && !PrivateSubnetAwsResource.where(vpc_id: peer_vpc_id).empty?
      fail Validation::ValidationFailed.new({peer_vpc_id: "#{peer_vpc_id} is the VPC of a Ubicloud private subnet, and peering two Ubicloud VPCs is not supported. Enter the ID of a VPC you manage outside Ubicloud."})
    end

    if location.gcp?
      unless private_subnet.dedicated_gcp_vpc?
        fail CloverError.new(400, "InvalidRequest", "Private subnet '#{private_subnet.name}' does not have its own VPC network, so it cannot be peered.")
      end

      path_project, peer_network = Validation::GCP_NETWORK_PATH_PATTERN.match(peer_vpc_id)&.captures
      unless path_project == peer_account_id
        fail Validation::ValidationFailed.new({peer_vpc_id: "#{peer_vpc_id} is not a VPC network in GCP project #{peer_account_id}."})
      end

      if location.project_id.nil? && !LocationCredentialGcp.where(project_id: peer_account_id, id: Location.where(project_id: nil).select(:id)).empty?
        fail Validation::ValidationFailed.new({peer_account_id: "#{peer_account_id} is Ubicloud's GCP project. Enter the ID of the GCP project that owns your VPC network."})
      end

      unless GcpVpc.where(name: peer_network, location_id: LocationCredentialGcp.where(project_id: peer_account_id).select(:id)).empty?
        fail Validation::ValidationFailed.new({peer_vpc_id: "#{peer_vpc_id} is a Ubicloud VPC network. Enter a VPC network in your own GCP project."})
      end
    end

    DB.transaction do
      private_subnet.project.lock!(:no_key_update)

      peerings = private_subnet.vpc_peerings_dataset
      unless peerings.where(peer_vpc_id:).empty?
        fail Validation::ValidationFailed.new({peer_vpc_id: "This private subnet already has a VPC peering with #{peer_vpc_id}. Delete it first. If you just deleted it, wait until it disappears."})
      end

      if peerings.count >= MAX_PER_PRIVATE_SUBNET
        fail CloverError.new(400, "InvalidRequest", "Private subnet '#{private_subnet.name}' already has #{MAX_PER_PRIVATE_SUBNET} VPC peerings, the maximum. Delete one first. If you just deleted one, wait until it disappears.")
      end

      subnets = PrivateSubnet.where(project_id: private_subnet.project_id, location_id: private_subnet.location_id).select(:id)
      if VpcPeering.where(private_subnet_id: subnets, state: PENDING_STATES).count >= MAX_PENDING_PER_PROJECT_LOCATION
        pending, action = if location.gcp?
          ["VPC peerings that are not connected", "Create your side of one, or delete one"]
        else
          ["VPC peering requests waiting to be accepted", "Accept or delete one"]
        end
        fail CloverError.new(400, "InvalidRequest", "This project already has #{MAX_PENDING_PER_PROJECT_LOCATION} #{pending} in #{location.display_name}. #{action} first. If you just deleted one, wait until it disappears.")
      end

      if location.aws? && !location.byoc
        location.lock!(:no_key_update)
        location_subnets = PrivateSubnet.where(location_id: private_subnet.location_id).select(:id)
        if VpcPeering.where(private_subnet_id: location_subnets, state: PENDING_STATES).count >= MAX_PENDING_PER_LOCATION
          Clog.emit("VPC peering location ceiling reached", {vpc_peering_location_ceiling: {location: location.ubid, project: private_subnet.project.ubid}})
          fail CloverError.new(400, "InvalidRequest", "Ubicloud has reached its limit of VPC peering requests waiting to be accepted in #{location.display_name}. Try again later, or contact support@ubicloud.com.")
        end
      end

      vp = VpcPeering.create(private_subnet_id: private_subnet.id, peer_account_id:, peer_vpc_id:)
      prog = if location.aws?
        VpcPeeringAwsResource.create_with_id(vp, peer_region: aws.fetch(:peer_region))
        "Vnet::Aws::VpcPeeringNexus"
      elsif location.gcp?
        VpcPeeringGcpResource.create_with_id(vp, peering_name: "ubicloud-#{vp.ubid}")
        "Vnet::Gcp::VpcPeeringNexus"
      else
        fail "VPC peering is not supported in #{location.provider} locations"
      end
      Strand.create_with_id(vp, prog:, label: "start")
    end
  end
end
