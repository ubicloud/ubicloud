# frozen_string_literal: true

# TODOBV: Name as accessor, hmm don't like it.
module PrivateSubnetAccessor
  def project_private_subnet_get(project, current_user)
    serializer = Serializers::Web::PrivateSubnet
    serializer.serialize(project.private_subnets_dataset.authorized(current_user.id, "PrivateSubnet:view").all)
  end

  def project_private_subnet_post(project, params)
    _ = Prog::Vnet::SubnetNexus.assemble(
      project.id,
      name: params["name"],
      location: params["location"]
    )
  end
end
