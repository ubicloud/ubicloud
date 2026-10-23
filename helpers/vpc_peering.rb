# frozen_string_literal: true

class Clover
  VPC_PEERING_PROVIDERS = %w[aws].freeze

  def vpc_peering_enabled?(location)
    Config.vpc_peering_enabled &&
      VPC_PEERING_PROVIDERS.include?(location.provider) &&
      @project.public_send(:"get_ff_vpc_peering_#{location.provider}") == true
  end

  def vpc_peerings_for(ps)
    ps.vpc_peerings(eager: [:vpc_peering_aws_resource, :semaphores])
  end
end
