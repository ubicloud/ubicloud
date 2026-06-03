# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "machine-image") do |r|
    next unless @project.get_ff_machine_image

    r.get api? do
      machine_image_list
    end

    r.on MACHINE_IMAGE_NAME_OR_UBID do |mi_name, mi_id|
      if mi_name
        r.post api? do
          machine_image_post(mi_name)
        end

        filter = {Sequel[:machine_image][:name] => mi_name}
      else
        filter = {Sequel[:machine_image][:id] => mi_id}
      end

      filter[:location_id] = @location.id
      @machine_image = mi = @project.machine_images_dataset.first(filter)
      check_found_object(mi)

      r.get true do
        authorize("MachineImage:view", mi)
        if api?
          Serializers::MachineImage.serialize(mi)
        else
          r.redirect mi, "/overview"
        end
      end

      r.patch api? do
        authorize("MachineImage:edit", mi)
        new_label = typecast_params.str("latest_version")

        DB.transaction do
          new_id = nil
          miv = nil
          if new_label
            miv = mi.versions_dataset.first(version: new_label)
            raise CloverError.new(400, "InvalidRequest", "Version #{new_label} not found") unless miv
            # FOR SHARE conflicts with destroy_version's UPDATE on the metal row, so
            # the enabled check below is consistent with what destroy_version commits.
            metal = miv.metal_dataset.for_share.first
            raise CloverError.new(400, "InvalidRequest", "Version #{new_label} is not ready") unless metal&.enabled
            new_id = miv.id
          end
          mi.update(latest_version_id: new_id)
          audit_log(mi, "update_latest_version", miv ? [miv] : [])
        end

        Serializers::MachineImage.serialize(mi.refresh)
      end

      r.delete api? do
        authorize("MachineImage:delete", mi)
        unless mi.versions_dataset.empty?
          raise CloverError.new(400, "InvalidRequest", "Machine image still has versions; destroy them first")
        end

        DB.transaction do
          audit_log(mi, "destroy")
          mi.destroy
        end

        204
      end

      r.rename(mi, perm: "MachineImage:edit", serializer: Serializers::MachineImage, template_prefix: "machine_image")

      r.on "version" do
        r.get api? do
          authorize("MachineImage:view", mi)
          paginated_result(mi.versions_dataset.eager(:metal), Serializers::MachineImageVersion, latest_version_id: mi.latest_version_id)
        end

        r.on(/([a-zA-Z0-9][a-zA-Z0-9._-]{0,63})/) do |version|
          r.post api? do
            authorize("MachineImage:edit", mi)
            if mi.versions_dataset.first(version:)
              raise CloverError.new(400, "InvalidRequest", "Version #{version} already exists for this machine image")
            end
            source_vm = source_vm_from_params

            DB.transaction do
              miv = assemble_machine_image_version(mi, version, source_vm)
              audit_log(mi, "create_version", [miv])
              Serializers::MachineImageVersion.serialize(miv, latest_version_id: mi.latest_version_id)
            end
          end

          r.delete api? do
            authorize("MachineImage:edit", mi)
            miv = mi.versions_dataset.first(version:)
            raise CloverError.new(404, "ResourceNotFound", "Machine image version not found") unless miv
            metal = miv.metal
            raise CloverError.new(400, "InvalidRequest", "Version has no metal record to destroy") unless metal

            DB.transaction do
              Prog::MachineImage::DestroyVersionMetal.assemble(metal)
              audit_log(mi, "destroy_version", [miv])
            end

            204
          end
        end
      end

      r.show_object(mi, actions: %w[overview versions settings], perm: "MachineImage:view", template: "machine_image/show")
    end
  end
end
