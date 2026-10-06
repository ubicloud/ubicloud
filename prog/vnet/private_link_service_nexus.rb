# frozen_string_literal: true

# Creates a service with its ports and provider rows and starts the provider
# nexus on it; holds no labels of its own.
class Prog::Vnet::PrivateLinkServiceNexus < Prog::Base
  subject_is :private_link_service

  DEFAULT_POSTGRES_PORTS = [[5432, 5432], [6432, 6432]].freeze

  def self.assemble(project_id:, private_subnet_id:, name:, allowed_principals:, postgres_resource_id:, ports:, ip_address_type:, aws_supported_regions:, aws_allowed_vpc_endpoints:)
    DB.transaction do
      unless (ps = PrivateSubnet[private_subnet_id])
        fail "No existing private subnet"
      end
      fail "Private link services are only supported on AWS" unless ps.location.aws?
      fail "Private link service must have at least one port" if ports.empty?
      unless (aws_supported_regions - PrivateLinkServiceAwsResource::SUPPORTED_REGIONS).empty?
        fail "Unsupported AWS region for cross-region access"
      end
      Validation.validate_name(name)

      private_dns_name = PrivateLinkService.default_private_dns_name(PostgresResource[postgres_resource_id]) if postgres_resource_id

      pls = PrivateLinkService.create(
        project_id:,
        location_id: ps.location_id,
        private_subnet_id: ps.id,
        postgres_resource_id:,
        name:,
        allowed_principals: Sequel.pg_array(allowed_principals, :text),
        private_dns_name:,
        ip_address_type:,
      )
      # One INSERT for all ports.
      port_ids = PrivateLinkServicePort.import(
        [:private_link_service_id, :port, :target_port],
        ports.map { |port, target_port| [pls.id, port, target_port] },
        return: :primary_key,
      )

      aws = PrivateLinkServiceAwsResource.create_with_id(pls, supported_regions: Sequel.pg_array((aws_supported_regions - [ps.location.name]).uniq.sort, :text))
      unless aws_allowed_vpc_endpoints.empty?
        PrivateLinkServiceAwsAllowedEndpoint.multi_insert(aws_allowed_vpc_endpoints.map { |vpc_endpoint_id, description| {private_link_service_aws_resource_id: aws.id, vpc_endpoint_id:, description:} })
      end
      PrivateLinkServicePortAwsResource.import([:id], port_ids.zip)

      Strand.create_with_id(pls, prog: "Vnet::Aws::PrivateLinkServiceNexus", label: "start")
    end
  end
end
