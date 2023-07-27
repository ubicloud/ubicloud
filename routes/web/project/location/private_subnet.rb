# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    @serializer = Serializers::Web::PrivateSubnet

    r.on String do |ps_name|
      ps = @project.private_subnets_dataset.where(location: @location).where { {Sequel[:private_subnet][:name] => ps_name} }.first

      unless ps
        response.status = 404
        r.halt
      end
      @ps = serialize(ps)

      r.get true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps.id)

        @nics = Serializers::Web::Nic.serialize(ps.nics)

        view "private_subnet/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:delete", ps.id)

        ps.incr_destroy

        return {message: "Deleting #{ps.name}"}.to_json
      end
    end
  end
end
