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
        Authorization.authorize(current_account.id, "Firewall:view", @project.id)
        Authorization.authorize(current_account.id, "Firewall:view", firewall.id)
        @firewall = Serializers::Firewall.serialize(fw, {detailed: true})

        if api?
          @firewall
        else
          project_subnets = @project.private_subnets_dataset.where(location: @location).authorized(current_account.id, "PrivateSubnet:view").all
          attached_subnets = fw.private_subnets_dataset.all
          @attachable_subnets = Serializers::PrivateSubnet.serialize(project_subnets.reject { |ps| attached_subnets.find { |as| as.id == ps.id } })

          view "networking/firewall/show"
        end
      end

      request.post %w[attach-subnet detach-subnet] do |action|
        Authorization.authorize(current_account.id, "PrivateSubnet:edit", @project.id)
        Authorization.authorize(current_account.id, "Firewall:view", firewall.id)

        private_subnet_id = if api?
          Validation.validate_request_body(request.body.read, ["private_subnet_id"])["private_subnet_id"]
        else
          r.params["private-subnet-id"]
        end

        private_subnet = PrivateSubnet.from_ubid(private_subnet_id) if private_subnet_id

        unless private_subnet && private_subnet.location == @location
          if api?
            fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{private_subnet_id}\" and the location \"#{location}\" is not found"})
          else
            flash["error"] = "Private subnet not found"
            r.redirect "#{@project.path}#{firewall.path}"
          end
        end

        # XXX: differing authorization between api and web routes!
        Authorization.authorize(current_account.id, "PrivateSubnet:edit", private_subnet.id) unless api?

        if action == "attach-subnet"
          firewall.associate_with_private_subnet(private_subnet)
          actioned = "attached to"
        else
          firewall.disassociate_from_private_subnet(private_subnet)
          actioned = "detached from"
        end

        if api?
          Serializers::Firewall.serialize(firewall, {detailed: true})
        else
          flash["notice"] = "Private subnet #{private_subnet.name} is #{actioned} the firewall"
          r.redirect "#{@project.path}#{firewall.path}"
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
