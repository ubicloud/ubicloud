# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    r.on String do |ps_name|
      ps = @project.private_subnets_dataset.where(location: @location).where { {Sequel[:private_subnet][:name] => ps_name} }.first

      unless ps
        response.status = 404
        r.halt
      end
      @ps = Serializers::PrivateSubnet.serialize(ps)

      r.get true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps.id)

        @nics = Serializers::Nic.serialize(ps.nics)

        view "networking/private_subnet/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:delete", ps.id)

        if ps.vms_dataset.count > 0
          response.status = 400
          return {message: "Private subnet has VMs attached, first, delete them."}.to_json
        end

        ps.incr_destroy

        return {message: "Deleting #{ps.name}"}.to_json
      end
    end
  end
end
