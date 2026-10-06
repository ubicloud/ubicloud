# frozen_string_literal: true

class Serializers::PrivateLinkService < Serializers::Base
  def self.serialize_internal(pls, options = {})
    base = {
      id: pls.ubid,
      name: pls.name,
      location: pls.display_location,
      private_subnet: pls.private_subnet.name,
      state: pls.display_state,
      postgres_resource: pls.postgres_resource&.ubid,
      ports: pls.ports.map { {port: it.port, target_port: it.target_port} },
      allowed_principals: pls.allowed_principals.to_a,
      ip_address_type: pls.ip_address_type,
      private_dns_name: pls.private_dns_name,
      private_hostname: pls.private_hostname,
    }

    if options[:detailed]
      base[:aws] = serialize_aws(pls.private_link_service_aws_resource)
    end

    base
  end

  def self.serialize_aws(aws)
    {
      service_name: aws.service_name,
      service_id: aws.service_id,
      supported_regions: aws.supported_regions.to_a,
      allowed_vpc_endpoints: aws.allowed_endpoints.map { {vpc_endpoint_id: it.vpc_endpoint_id, description: it.description} },
      registered_target_ips: aws.registered_target_ips.map(&:to_s),
      private_dns_verification_state: aws.private_dns_verification_state,
    }
  end
end
