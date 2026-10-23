# frozen_string_literal: true

class Clover
  # The result is a Roda matcher, so the flag's stored JSON must not reach it as is.
  def vpc_peering_enabled?(location)
    Config.vpc_peering_enabled && location.aws? && @project.get_ff_vpc_peering_aws == true
  end

  def vpc_peerings_for(ps)
    ps.vpc_peerings(eager: [:vpc_peering_aws_resource, :semaphores])
  end
end
