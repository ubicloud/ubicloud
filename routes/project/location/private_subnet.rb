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
      peering_enabled = vpc_peering_enabled?(@location)

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

        if peering_enabled && !ps.vpc_peerings_dataset.not_deleting.empty?
          fail DependencyError.new("Private subnet '#{ps.name}' has VPC peerings, first, delete them.")
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

      actions = peering_enabled ? %w[overview vms networking vpc-peering settings].freeze : %w[overview vms networking settings].freeze
      r.show_object(ps, actions:, perm: "PrivateSubnet:view", template: "networking/private_subnet/show")

      r.on peering_enabled, "vpc-peering" do
        r.is do
          r.get api? do
            authorize("PrivateSubnet:view", ps)
            peerings = vpc_peerings_for(ps)
            {items: Serializers::VpcPeering.serialize(peerings), count: peerings.count}
          end

          r.post do
            authorize("PrivateSubnet:edit", ps)
            handle_validation_failure("networking/private_subnet/show") { @page = "vpc-peering" }
            peer_account_id = typecast_params.nonempty_str!("peer_account_id").delete("- ")
            peer_vpc_id = typecast_params.nonempty_str!("peer_vpc_id").strip.downcase
            peer_region = typecast_params.dig(:nonempty_str, "aws", "peer_region")&.strip&.downcase || @location.name
            Validation.validate_aws_vpc_peering(peer_account_id:, peer_vpc_id:, peer_region:)
            vp = DB.transaction do
              peering = Prog::Vnet::VpcPeeringNexus.assemble(ps, peer_account_id:, peer_vpc_id:, aws: {peer_region:}).subject
              audit_log(peering, "create", ps)
              peering
            end

            if api?
              Serializers::VpcPeering.serialize(vp)
            else
              flash["notice"] = "Ubicloud is requesting the peering. Accept it in AWS account #{vp.peer_account_id} when it appears below."
              r.redirect ps, "/vpc-peering"
            end
          end
        end

        r.on :ubid_uuid do |id|
          vp = ps.vpc_peerings_dataset[id:]
          check_found_object(vp)

          r.get api?, true do
            authorize("PrivateSubnet:view", ps)
            Serializers::VpcPeering.serialize(vp)
          end

          r.delete true do
            authorize("PrivateSubnet:edit", ps)
            DB.transaction do
              vp.incr_destroy
              audit_log(vp, "destroy", ps)
            end

            if api?
              204
            else
              flash["notice"] = "VPC peering with #{vp.peer_vpc_id} is being deleted"
              r.redirect ps, "/vpc-peering"
            end
          end
        end
      end
    end
  end
end
