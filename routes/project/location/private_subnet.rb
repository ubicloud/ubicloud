# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "private-subnet") do |r|
    r.get api? do
      private_subnet_list
    end

    r.on PRIVATE_SUBNET_NAME_OR_UBID do |ps_name, ps_id|
      if ps_name
        r.post api? do
          check_visible_location
          private_subnet_post(ps_name)
        end

        filter = {Sequel[:private_subnet][:name] => ps_name}
      else
        filter = {Sequel[:private_subnet][:id] => ps_id}
      end

      filter[:location_id] = @location.id
      ps = @ps = @project.private_subnets_dataset.first(filter)
      check_found_object(ps)

      r.post "connect" do
        private_subnet_connection_action("connect", typecast_params.ubid_uuid!("connected-subnet-id"))
      end

      r.post "disconnect", :ubid_uuid do |id|
        private_subnet_connection_action("disconnect", id)
      end

      r.get true do
        authorize("PrivateSubnet:view", ps)
        if api?
          Serializers::PrivateSubnet.serialize(ps)
        else
          r.redirect ps, "/overview"
        end
      end

      r.delete true do
        authorize("PrivateSubnet:delete", ps)
        handle_validation_failure("networking/private_subnet/settings")

        unless ps.attached_vms.empty?
          fail DependencyError.new("Private subnet '#{ps.name}' has VMs attached, first, delete them.")
        end

        DB.transaction do
          ps.incr_destroy(request.get_header("X-Request-ID"))
          audit_log(ps, "destroy")
        end

        if web?
          flash["notice"] = "Private subnet scheduled for deletion."
          r.redirect @project, "/private-subnet"
        else
          204
        end
      end

      r.rename ps, perm: "PrivateSubnet:edit", serializer: Serializers::PrivateSubnet, template_prefix: "networking/private_subnet"

      r.show_object(ps, actions: %w[overview vms networking settings], perm: "PrivateSubnet:view", template: "networking/private_subnet/show")
    end
  end
end
