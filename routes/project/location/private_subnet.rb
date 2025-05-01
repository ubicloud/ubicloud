# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    r.get api? do
      private_subnet_list
    end

    r.on PRIVATE_SUBNET_NAME_OR_UBID do |ps_name, ps_id|
      if ps_name
        r.post true do
          check_visible_location
          private_subnet_post(ps_name)
        end

        filter = {Sequel[:private_subnet][:name] => ps_name}
      else
        filter = {Sequel[:private_subnet][:id] => UBID.to_uuid(ps_id)}
      end

      filter[:location_id] = @location.id
      ps = @project.private_subnets_dataset.eager(:location).first(filter)
      check_found_object(ps)

      r.post "connect" do
        authorize("PrivateSubnet:connect", ps.id)
        subnet = PrivateSubnet.from_ubid(r.params["connected-subnet-id"])
        unless subnet
          if api?
            response.status = 400
            next {error: {code: 400, type: "InvalidRequest", message: "Subnet to be connected not found"}}
          else
            flash["error"] = "Subnet to be connected not found"
            r.redirect "#{@project.path}#{ps.path}"
          end
        end

        authorize("PrivateSubnet:connect", subnet.id)
        ps.connect_subnet(subnet)
        if api?
          Serializers::PrivateSubnet.serialize(ps)
        else
          flash["notice"] = "#{subnet.name} will be connected in a few seconds"
          r.redirect "#{@project.path}#{ps.path}"
        end
      end

      r.post "disconnect", String do |disconnecting_ps_ubid|
        authorize("PrivateSubnet:disconnect", ps.id)
        subnet = PrivateSubnet.from_ubid(disconnecting_ps_ubid)
        unless subnet
          response.status = 400
          next {error: {code: 400, type: "InvalidRequest", message: "Subnet to be disconnected not found"}}
        end

        authorize("PrivateSubnet:disconnect", subnet.id)
        ps.disconnect_subnet(subnet)
        if api?
          Serializers::PrivateSubnet.serialize(ps)
        else
          flash["notice"] = "#{subnet.name} will be disconnected in a few seconds"
          204
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
          connectable_subnets = ps.project.private_subnets.select do |ps1|
            ps1_id = ps1.id
            ps1_id != ps.id && !ps.connected_subnets.find { |cs| cs.id == ps1_id }
          end
          @connectable_subnets = Serializers::PrivateSubnet.serialize(connectable_subnets)
          view "networking/private_subnet/show"
        end
      end

      request.delete true do
        authorize("PrivateSubnet:delete", ps.id)
        unless ps.vms.all? { it.destroy_set? || it.strand.nil? || it.strand.label == "destroy" }
          fail DependencyError.new("Private subnet '#{ps.name}' has VMs attached, first, delete them.")
        end

        ps.incr_destroy
        204
      end
    end
  end
end
