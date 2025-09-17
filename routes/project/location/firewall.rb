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
        filter = {Sequel[:firewall][:id] => firewall_id}
      end

      filter[:location_id] = @location.id
      @firewall = firewall = @project.firewalls_dataset.first(filter)
      check_found_object(firewall)

      r.is do
        r.delete do
          authorize("Firewall:delete", firewall)
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
          authorize("Firewall:view", firewall)

          if api?
            Serializers::Firewall.serialize(firewall, {detailed: true})
          else
            r.redirect firewall, "/overview"
          end
        end
      end

      r.rename firewall, perm: "Firewall:edit", serializer: Serializers::Firewall, template_prefix: "networking/firewall"

      r.show_object(firewall, actions: %w[overview networking settings], perm: "Firewall:view", template: "networking/firewall/show")

      r.post %w[attach-subnet detach-subnet] do |action|
        authorize("Firewall:view", firewall)
        handle_validation_failure("networking/firewall/show") { @page = "networking" }

        unless (private_subnet = authorized_private_subnet(location_id: @location.id, perm: "PrivateSubnet:edit"))
          fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{typecast_params.str("private_subnet_id")}\" and the location \"#{@location.display_name}\" is not found"})
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
          r.redirect firewall, "/networking"
        end
      end

      r.on "firewall-rule" do
        r.post true do
          authorize("Firewall:edit", firewall)
          handle_validation_failure("networking/firewall/show") { @page = "networking" }

          parsed_cidr = Validation.validate_cidr(typecast_params.str!("cidr"))
          port_range = Validation.validate_port_range(typecast_params.str("port_range"))
          pg_range = Sequel.pg_range(port_range.first..port_range.last)

          firewall_rule = nil
          DB.transaction do
            firewall_rule = firewall.insert_firewall_rule(parsed_cidr.to_s, pg_range)
            audit_log(firewall_rule, "create", firewall)
          end

          if api?
            Serializers::FirewallRule.serialize(firewall_rule)
          else
            flash["notice"] = "Firewall rule is created"
            r.redirect firewall, "/networking"
          end
        end

        r.is :ubid_uuid do |id|
          firewall_rule = firewall.firewall_rules_dataset[id:]
          check_found_object(firewall_rule)

          r.delete do
            authorize("Firewall:edit", firewall)
            DB.transaction do
              firewall.remove_firewall_rule(firewall_rule)
              audit_log(firewall_rule, "destroy", firewall)
            end

            if api?
              204
            else
              {message: "Firewall rule deleted"}
            end
          end

          r.get api? do
            authorize("Firewall:view", firewall)
            Serializers::FirewallRule.serialize(firewall_rule)
          end
        end
      end
    end
  end
end
