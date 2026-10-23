# frozen_string_literal: true

class Serializers::VpcPeering < Serializers::Base
  def self.serialize_internal(vp, options = {})
    ps = vp.private_subnet
    base = {
      id: vp.ubid,
      state: vp.display_state,
      state_message: vp.state_message,
      private_subnet_id: ps.ubid,
      location: ps.display_location,
      local_cidr: ps.net4.to_s,
      peer_account_id: vp.peer_account_id,
      peer_vpc_id: vp.peer_vpc_id,
      peer_cidrs: vp.peer_cidrs.map(&:to_s),
      created_at: vp.created_at.utc.iso8601,
    }
    if (aws = vp.vpc_peering_aws_resource)
      base[:aws] = {
        peer_region: aws.peer_region,
        peering_connection_id: aws.peering_connection_id,
        requester_account_id: aws.requester_account_id,
        requester_vpc_id: ps.private_subnet_aws_resource.vpc_id,
        expires_at: aws.expires_at&.utc&.iso8601,
      }
    end
    base
  end
end
