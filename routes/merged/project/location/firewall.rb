# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get api? do
      result = @project.firewalls_dataset.where(location: @location).authorized(current_account.id, "Firewall:view").eager(:firewall_rules).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: Serializers::Firewall.serialize(result[:records]),
        count: result[:count]
      }
    end

    r.on NAME_OR_UBID do |firewall_name, firewall_id|
      if firewall_name
        r.post api? do
          Authorization.authorize(current_account.id, "Firewall:create", @project.id)

          allowed_optional_parameters = ["description"]
          request_body_params = Validation.validate_request_body(r.body.read, [], allowed_optional_parameters)
          Validation.validate_name(firewall_name)

          firewall = Firewall.create_with_id(name: firewall_name, location: @location, description: request_body_params["description"] || "")
          firewall.associate_with_project(@project)

          Serializers::Firewall.serialize(firewall)
        end

        filter = {Sequel[:firewall][:name] => firewall_name}
      else
        filter = {Sequel[:firewall][:id] => UBID.to_uuid(firewall_id)}
      end

      filter[:location] = @location
      @firewall = @project.firewalls_dataset.first(filter)
      user = current_account
      fw = firewall = @firewall
      location = @location
      @fw = Serializers::Firewall.serialize(fw)

      unless firewall
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      request.delete true do
        Authorization.authorize(current_account.id, "Firewall:delete", @project.id)
        Authorization.authorize(current_account.id, "Firewall:delete", firewall.id)
        firewall.private_subnets.map { Authorization.authorize(current_account.id, "PrivateSubnet:edit", _1.id) }
        firewall.destroy

        if api?
          response.status = 204
          nil
        else
          {message: "Deleting #{fw.name}"}
        end
      end

      request.get true do
        if api?
          Authorization.authorize(user.id, "Firewall:view", @project.id)

          Serializers::Firewall.serialize(firewall, {detailed: true})
        else
          Authorization.authorize(current_account.id, "Firewall:view", fw.id)
          project_subnets = @project.private_subnets_dataset.where(location: @location).authorized(current_account.id, "PrivateSubnet:view").all
          attached_subnets = fw.private_subnets_dataset.all
          @attachable_subnets = Serializers::PrivateSubnet.serialize(project_subnets.reject { |ps| attached_subnets.map(&:id).include?(ps.id) })
          @firewall = Serializers::Firewall.serialize(fw, {detailed: true})

          view "networking/firewall/show"
        end
      end

      request.post "attach-subnet" do
        if api?
          Authorization.authorize(user.id, "PrivateSubnet:edit", @project.id)

          required_parameters = ["private_subnet_id"]
          request_body_params = Validation.validate_request_body(request.body.read, required_parameters)

          private_subnet = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
          unless private_subnet && private_subnet.location == @location
            fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" and the location \"#{location}\" is not found"})
          end

          firewall.associate_with_private_subnet(private_subnet)

          Serializers::Firewall.serialize(firewall, {detailed: true})
        else
          Authorization.authorize(current_account.id, "Firewall:view", fw.id)
          ps = PrivateSubnet.from_ubid(r.params["private-subnet-id"])
          unless ps && ps.location == @location
            flash["error"] = "Private subnet not found"
            response.status = 404
            r.redirect "#{@project.path}#{fw.path}"
          end

          Authorization.authorize(current_account.id, "PrivateSubnet:edit", ps.id)

          fw.associate_with_private_subnet(ps)

          flash["notice"] = "Private subnet is attached to the firewall"

          r.redirect "#{@project.path}#{fw.path}"
        end
      end

      request.post "detach-subnet" do
        if api?
          Authorization.authorize(current_account.id, "PrivateSubnet:edit", @project.id)

          required_parameters = ["private_subnet_id"]
          request_body_params = Validation.validate_request_body(request.body.read, required_parameters)

          private_subnet = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
          unless private_subnet && private_subnet.location == @location
            fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" and the location \"#{location}\" is not found"})
          end

          firewall.disassociate_from_private_subnet(private_subnet)

          Serializers::Firewall.serialize(firewall, {detailed: true})
        else
          Authorization.authorize(current_account.id, "Firewall:view", fw.id)
          ps = PrivateSubnet.from_ubid(r.params["private-subnet-id"])
          unless ps && ps.location == @location
            flash["error"] = "Private subnet not found"
            response.status = 404
            r.redirect "#{@project.path}#{fw.path}"
          end

          Authorization.authorize(current_account.id, "PrivateSubnet:edit", ps.id)

          fw.disassociate_from_private_subnet(ps)

          flash["notice"] = "Private subnet #{ps.name} is detached from the firewall"

          r.redirect "#{@project.path}#{fw.path}"
        end
      end

      r.on api? do
        request.hash_branches(:api_project_location_firewall_prefix)
      end

      r.on "firewall-rule" do
        r.post true do
          Authorization.authorize(current_account.id, "Firewall:edit", fw.id)

          port_range = if r.params["port_range"].empty?
            [0, 65535]
          else
            Validation.validate_port_range(r.params["port_range"])
          end

          parsed_cidr = Validation.validate_cidr(r.params["cidr"])
          pg_range = Sequel.pg_range(port_range.first..port_range.last)

          fw.insert_firewall_rule(parsed_cidr.to_s, pg_range)
          flash["notice"] = "Firewall rule is created"

          r.redirect "#{@project.path}#{fw.path}"
        end

        r.is String do |firewall_rule_ubid|
          r.delete true do
            Authorization.authorize(current_account.id, "Firewall:edit", fw.id)
            fwr = FirewallRule.from_ubid(firewall_rule_ubid)
            unless fwr
              response.status = 204
              r.halt
            end

            fw.remove_firewall_rule(fwr)

            {message: "Firewall rule deleted"}
          end
        end
      end
    end

    # 204 response for invalid names
    r.is String do |firewall_name|
      r.post do
        Validation.validate_name(firewall_name)
      end

      r.delete do
        response.status = 204
        nil
      end
    end
  end

  hash_branch(:api_project_location_prefix, "firewall", &branch)
  hash_branch(:project_location_prefix, "firewall", &branch)
end
