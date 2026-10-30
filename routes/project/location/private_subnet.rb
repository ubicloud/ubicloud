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

      vpc = ps.location.gcp? ? ps.gcp_vpc : nil
      r.on !!(vpc && (gcp_vpc_peering_enabled?(ps) || vpc.peer_network)), "vpc-peering" do
        r.get true do
          authorize("PrivateSubnet:view", ps)
          gcp_vpc_peering_details(vpc)
        end

        r.post true do
          authorize("PrivateSubnet:edit", ps)
          handle_validation_failure("networking/private_subnet/show") { @page = "networking" }
          DB.transaction do
            ps.lock!(:no_key_update)
            vpc.lock!(:no_key_update)
            unless gcp_vpc_peering_enabled?(ps)
              fail CloverError.new(400, "InvalidRequest", "VPC peering is not enabled for this private subnet")
            end
            if vpc.peering_destroying?
              fail CloverError.new(400, "InvalidRequest", "Private subnet is being deleted")
            end
            if vpc.peer_network
              fail CloverError.new(400, "InvalidRequest", "Only one peer is supported. Disconnect the existing peer and wait for removal before creating another.")
            end
            vpc.configure_peering(
              peer_project_id: typecast_params.nonempty_str!("peer_project_id").strip,
              peer_network_name: typecast_params.nonempty_str!("peer_network_name").strip,
            )
            @project.postgres_resources_dataset.where(private_subnet_id: ps.id).each(&:incr_refresh_dns_record)
            audit_log(ps, "create_vpc_peering")
          end

          if api?
            gcp_vpc_peering_details(vpc)
          else
            flash["notice"] = "VPC peering is being configured. Create the matching peering in your GCP project."
            r.redirect ps, "/networking"
          end
        end

        r.delete true do
          authorize("PrivateSubnet:edit", ps)
          DB.transaction do
            vpc.lock!(:no_key_update)
            if vpc.peer_network
              vpc.update(peering_state: "deleting", peering_state_message: nil)
              vpc.incr_update_peering
            end
            audit_log(ps, "delete_vpc_peering")
          end

          if api?
            204
          else
            flash["notice"] = "VPC peering is being disconnected."
            r.redirect ps, "/networking"
          end
        end
      end

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
          ps.incr_destroy
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

      r.show_object(ps, actions: %w[overview vms networking settings].freeze, perm: "PrivateSubnet:view", template: "networking/private_subnet/show")
    end
  end
end
