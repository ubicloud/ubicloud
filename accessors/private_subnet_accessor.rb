# frozen_string_literal: true

module PrivateSubnetAccessor
  def self.get_all(project, current_user)
    serializer = Serializers::Web::PrivateSubnet
    serializer.serialize(project.private_subnets_dataset.authorized(current_user.id, "PrivateSubnet:view").all)
  end

  def self.post(project, params)
    _ = Prog::Vnet::SubnetNexus.assemble(
      project.id,
      name: params["name"],
      location: params["location"]
    )
  end

  def self.get(project)
    project.private_subnets_dataset.where { {Sequel[:private_subnet][:name] => ps_name} }.first
  end

  def self.delete(ps)
    ps.incr_destroy
  end
end
