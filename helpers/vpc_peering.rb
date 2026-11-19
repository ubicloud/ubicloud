# frozen_string_literal: true

class Clover
  # The result is a Roda matcher, so the flag's stored JSON must not reach it as is.
  def vpc_peering_enabled?(ps)
    return false unless Config.vpc_peering_enabled

    location = ps.location
    if location.aws?
      !location.byoc || @project.get_ff_vpc_peering_aws == true
    elsif location.gcp?
      @project.get_ff_vpc_peering_gcp == true && ps.dedicated_gcp_vpc?
    else
      false
    end
  end

  def vpc_peerings_for(ps)
    ps.vpc_peerings(eager: [:vpc_peering_aws_resource, :vpc_peering_gcp_resource, :semaphores])
  end
end
