# frozen_string_literal: true

class CloverWeb
  CloverBase.run_on_location :get_private_subnet do |project, name|
    project.private_subnets_dataset.where { {Sequel[:private_subnet][:name] => name} }.first
  end

  CloverBase.run_on_location :delete_private_subnet do |ps|
    if ps.vms_dataset.count > 0
      return {message: "Private subnet has VMs attached, first, delete them."}.to_json
    end

    ps.incr_destroy
  end

  CloverBase.run_on_location :get_private_subnet_nics do |ps|
    ps.nics
  end

  hash_branch(:project_location_prefix, "private-subnet") do |r|
    @serializer = Serializers::Web::PrivateSubnet

    r.on String do |ps_name|
      ps = get_private_subnet(@location, @project, ps_name)

      unless ps
        response.status = 404
        r.halt
      end
      @ps = serialize(ps)

      r.get true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps.id) # It is ok as we keep all authorization tables sync

        @nics = Serializers::Web::Nic.serialize(get_private_subnet_nics(@location, ps))

        view "private_subnet/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:delete", ps.id)

        delete_private_subnet(@location, ps)

        return {message: "Deleting #{ps.name}"}.to_json
      end
    end
  end
end
