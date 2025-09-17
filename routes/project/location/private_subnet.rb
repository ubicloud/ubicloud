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
        authorize("PrivateSubnet:connect", ps)
        handle_validation_failure("networking/private_subnet/show") { @page = "networking" }
        unless (subnet = authorized_private_subnet(key: "connected-subnet-id", perm: "PrivateSubnet:connect"))
          raise CloverError.new(400, "InvalidRequest", "Subnet to be connected not found")
        end

        DB.transaction do
          ps.connect_subnet(subnet)
          audit_log(ps, "connect", subnet)
        end

        if api?
          Serializers::PrivateSubnet.serialize(ps)
        else
          flash["notice"] = "#{subnet.name} will be connected in a few seconds"
          r.redirect ps, "/networking"
        end
      end

      r.post "disconnect", :ubid_uuid do |id|
        authorize("PrivateSubnet:disconnect", ps)
        handle_validation_failure("networking/private_subnet/show") { @page = "networking" }
        unless (subnet = authorized_private_subnet(id:, perm: "PrivateSubnet:disconnect"))
          raise CloverError.new(400, "InvalidRequest", "Subnet to be disconnected not found")
        end

        DB.transaction do
          ps.disconnect_subnet(subnet)
          audit_log(ps, "disconnect", subnet)
        end

        if api?
          Serializers::PrivateSubnet.serialize(ps)
        else
          flash["notice"] = "#{subnet.name} will be disconnected in a few seconds"
          r.redirect ps, "/networking"
        end
      end

      r.is do
        r.get do
          authorize("PrivateSubnet:view", ps)
          if api?
            Serializers::PrivateSubnet.serialize(ps)
          else
            r.redirect ps, "/overview"
          end
        end

        r.delete do
          authorize("PrivateSubnet:delete", ps)

          vms_dataset = ps.vms_dataset
            .association_join(:strand)
            .exclude(label: "destroy")
            .exclude(Sequel[:vm][:id] => Semaphore
              .where(
                strand_id: ps.nics_dataset.select(:vm_id),
                name: "destroy"
              )
              .select(:strand_id))

          unless vms_dataset.empty?
            fail DependencyError.new("Private subnet '#{ps.name}' has VMs attached, first, delete them.")
          end

          DB.transaction do
            ps.incr_destroy
            audit_log(ps, "destroy")
          end

          204
        end
      end

      r.rename ps, perm: "PrivateSubnet:edit", serializer: Serializers::PrivateSubnet, template_prefix: "networking/private_subnet"

      r.show_object(ps, actions: %w[overview vms networking settings], perm: "PrivateSubnet:view", template: "networking/private_subnet/show")
    end
  end
end
