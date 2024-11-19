# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    r.get api? do
      private_subnet_list
    end

    r.on NAME_OR_UBID do |ps_name, ps_id|
      if ps_name
        r.post true do
          private_subnet_post(ps_name)
        end

        filter = {Sequel[:private_subnet][:name] => ps_name}
      else
        filter = {Sequel[:private_subnet][:id] => UBID.to_uuid(ps_id)}
      end

      filter[:location] = @location
      ps = @project.private_subnets_dataset.first(filter)

      unless ps
        response.status = request.delete? ? 204 : 404
        next
      end

      if web?
        r.post "connect" do
          authorize("PrivateSubnet:connect", ps.id)
          subnet = PrivateSubnet.from_ubid(r.params["connected-subnet-ubid"])
          authorize("PrivateSubnet:connect", subnet.id)
          ps.connect_subnet(subnet)
          flash["notice"] = "#{subnet.name} will be connected in a few seconds"
          r.redirect "#{@project.path}#{ps.path}"
        end

        r.post "disconnect", String do |disconnecting_ps_ubid|
          authorize("PrivateSubnet:disconnect", ps.id)
          subnet = PrivateSubnet.from_ubid(disconnecting_ps_ubid)
          authorize("PrivateSubnet:disconnect", subnet.id)
          ps.disconnect_subnet(subnet)
          flash["notice"] = "#{subnet.name} will be disconnected in a few seconds"
          ""
        end
      end

      request.get true do
        authorize("PrivateSubnet:view", ps.id)
        @ps = Serializers::PrivateSubnet.serialize(ps)
        if api?
          @ps
        else
          @nics = Serializers::Nic.serialize(ps.nics)
          @connected_subnets = Serializers::PrivateSubnet.serialize(ps.connected_subnets)
          connectable_subnets = ps.projects.first.private_subnets.select do |ps1|
            ps1_id = ps1.id
            ps1_id != ps.id && !ps.connected_subnets.find { |cs| cs.id == ps1_id }
          end
          @connectable_subnets = Serializers::PrivateSubnet.serialize(connectable_subnets)
          view "networking/private_subnet/show"
        end
      end

      request.delete true do
        authorize("PrivateSubnet:delete", ps.id)
        unless ps.vms_dataset.empty?
          fail DependencyError.new("Private subnet '#{ps.name}' has VMs attached, first, delete them.")
        end

        ps.incr_destroy
        response.status = 204
        nil
      end
    end

    # 204 response for invalid names
    r.is String do |ps_name|
      r.post do
        private_subnet_post(ps_name)
      end

      r.delete do
        response.status = 204
        nil
      end
    end
  end
end
