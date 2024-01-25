# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    @serializer = Serializers::Api::PrivateSubnet

    r.on String do |ps_name|
      ps = @project.private_subnets_dataset.where(location: @location).where { {Sequel[:private_subnet][:name] => ps_name} }.first

      r.get true do
        unless ps
          response.status = 404
          r.halt
        end

        Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps.id)

        serialize(ps)
      end

      r.delete true do
        if ps
          Authorization.authorize(@current_user.id, "PrivateSubnet:delete", ps.id)

          if ps.vms_dataset.count > 0
            fail ErrorCodes::DependencyError.new("Private subnet has VMs attached, first, delete them.")
          end

          ps.incr_destroy
        end

        response.status = 204
        r.halt
      end
    end
  end
end
