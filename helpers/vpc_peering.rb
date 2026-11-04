# frozen_string_literal: true

class Clover
  VPC_PEERING_PROVIDERS = %w[aws gcp].freeze

  # The result is a Roda matcher, so the flag's stored JSON must not reach it as is.
  def vpc_peering_enabled?(ps)
    location = ps.location
    Config.vpc_peering_enabled &&
      VPC_PEERING_PROVIDERS.include?(location.provider) &&
      @project.public_send(:"get_ff_vpc_peering_#{location.provider}") == true &&
      (!location.gcp? || ps.dedicated_gcp_vpc?)
  end

  def vpc_peerings_for(ps)
    ps.vpc_peerings(eager: [:vpc_peering_aws_resource, :vpc_peering_gcp_resource, :semaphores])
  end
end
