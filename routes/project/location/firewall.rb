# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "firewall") do |r|
    r.get api? do
      firewall_list_api_response(firewall_list_dataset)
    end

    r.on FIREWALL_NAME_OR_UBID do |firewall_name, firewall_id|
      if firewall_name
        r.post api? do
          check_visible_location
          firewall_post(firewall_name)
        end

        filter = {Sequel[:firewall][:name] => firewall_name}
      else
        filter = {Sequel[:firewall][:id] => UBID.to_uuid(firewall_id)}
      end

      filter[:location_id] = @location.id
      @firewall = firewall = @project.firewalls_dataset.first(filter)
      check_found_object(firewall)

      r.is do
        r.delete do
          authorize("Firewall:delete", firewall.id)
          ds = firewall.private_subnets_dataset
          unless ds.exclude(id: dataset_authorize(ds, "PrivateSubnet:edit").select(:id)).empty?
            fail Authorization::Unauthorized
          end

          DB.transaction do
            firewall.destroy
            audit_log(firewall, "destroy")
          end
          204
        end

        r.get do
          authorize("Firewall:view", firewall.id)

          if api?
            Serializers::Firewall.serialize(firewall, {detailed: true})
          else
            view "networking/firewall/show"
          end
        end
      end

      r.post %w[attach-subnet detach-subnet] do |action|
        authorize("Firewall:view", firewall.id)

        unless (private_subnet = authorized_private_subnet(location_id: @location.id, perm: "PrivateSubnet:edit"))
          if api?
            fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{typecast_params.str("private_subnet_id")}\" and the location \"#{@location.display_name}\" is not found"})
          else
            flash["error"] = "Private subnet not found"
            r.redirect "#{@project.path}#{firewall.path}"
          end
        end

        actioned = nil

        DB.transaction do
          if action == "attach-subnet"
            firewall.associate_with_private_subnet(private_subnet)
            audit_log(firewall, "associate", private_subnet)
            actioned = "attached to"
          else
            firewall.disassociate_from_private_subnet(private_subnet)
            audit_log(firewall, "disassociate", private_subnet)
            actioned = "detached from"
          end
        end

        if api?
          Serializers::Firewall.serialize(firewall, {detailed: true})
        else
          flash["notice"] = "Private subnet #{private_subnet.name} is #{actioned} the firewall"
          r.redirect "#{@project.path}#{firewall.path}"
        end
      end

      r.api do
        r.hash_branches(:project_location_firewall_prefix)
      end

      r.on "firewall-rule" do
        r.post true do
          authorize("Firewall:edit", firewall.id)
          handle_validation_failure("networking/firewall/show")

          parsed_cidr = Validation.validate_cidr(typecast_params.str!("cidr"))
          port_range = Validation.validate_port_range(typecast_params.str("port_range"))
          pg_range = Sequel.pg_range(port_range.first..port_range.last)

          DB.transaction do
            firewall_rule = firewall.insert_firewall_rule(parsed_cidr.to_s, pg_range)
            audit_log(firewall_rule, "create", firewall)
          end

          flash["notice"] = "Firewall rule is created"

          r.redirect "#{@project.path}#{firewall.path}"
        end

        r.delete :ubid_uuid do |id|
          authorize("Firewall:edit", firewall.id)
          next 204 unless (fwr = firewall.firewall_rules_dataset[id:])

          DB.transaction do
            firewall.remove_firewall_rule(fwr)
            audit_log(fwr, "destroy")
          end

          {message: "Firewall rule deleted"}
        end
      end
    end
  end
end
