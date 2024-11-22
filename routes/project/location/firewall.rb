# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "firewall") do |r|
    r.get api? do
      firewall_list_api_response(firewall_list_dataset)
    end

    r.on NAME_OR_UBID do |firewall_name, firewall_id|
      if firewall_name
        r.post api? do
          firewall_post(firewall_name)
        end

        filter = {Sequel[:firewall][:name] => firewall_name}
      else
        filter = {Sequel[:firewall][:id] => UBID.to_uuid(firewall_id)}
      end

      filter[:location] = @location
      firewall = @project.firewalls_dataset.first(filter)

      unless firewall
        response.status = r.delete? ? 204 : 404
        next
      end

      r.delete true do
        authorize("Firewall:delete", firewall.id)
        firewall.private_subnets.map { authorize("PrivateSubnet:edit", _1.id) }
        firewall.destroy

        if api?
          response.status = 204
          nil
        else
          {message: "Deleting #{firewall.name}"}
        end
      end

      r.get true do
        authorize("Firewall:view", firewall.id)
        @firewall = Serializers::Firewall.serialize(firewall, {detailed: true})

        if api?
          @firewall
        else
          project_subnets = dataset_authorize(@project.private_subnets_dataset.where(location: @location), "PrivateSubnet:view").all
          attached_subnets = firewall.private_subnets_dataset.all
          @attachable_subnets = Serializers::PrivateSubnet.serialize(project_subnets.reject { |ps| attached_subnets.find { |as| as.id == ps.id } })

          view "networking/firewall/show"
        end
      end

      r.post %w[attach-subnet detach-subnet] do |action|
        authorize("Firewall:view", firewall.id)

        private_subnet_id = validate_request_params(["private_subnet_id"])["private_subnet_id"]
        private_subnet = PrivateSubnet.from_ubid(private_subnet_id)

        unless private_subnet && private_subnet.location == @location
          if api?
            fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{private_subnet_id}\" and the location \"#{@location}\" is not found"})
          else
            flash["error"] = "Private subnet not found"
            r.redirect "#{@project.path}#{firewall.path}"
          end
        end

        authorize("PrivateSubnet:edit", private_subnet.id)

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
        @firewall = firewall
        r.hash_branches(:project_location_firewall_prefix)
      end

      r.on "firewall-rule" do
        r.post true do
          authorize("Firewall:edit", firewall.id)

          port_range = if r.params["port_range"].empty?
            [0, 65535]
          else
            Validation.validate_port_range(r.params["port_range"])
          end

          parsed_cidr = Validation.validate_cidr(r.params["cidr"])
          pg_range = Sequel.pg_range(port_range.first..port_range.last)

          firewall.insert_firewall_rule(parsed_cidr.to_s, pg_range)
          flash["notice"] = "Firewall rule is created"

          r.redirect "#{@project.path}#{firewall.path}"
        end

        r.delete String do |firewall_rule_ubid|
          authorize("Firewall:edit", firewall.id)
          fwr = FirewallRule.from_ubid(firewall_rule_ubid)
          unless fwr
            response.status = 204
            next
          end

          firewall.remove_firewall_rule(fwr)

          {message: "Firewall rule deleted"}
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
end
