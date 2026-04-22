# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "machine-image") do |r|
    next unless @project.get_ff_machine_image

    r.on api? do
      r.get true do
        machine_image_list
      end

      r.on MACHINE_IMAGE_NAME_OR_UBID do |mi_name, mi_id|
        if mi_name
          r.post true do
            check_visible_location
            authorize("MachineImage:create", @project)
            Validation.validate_name(mi_name)

            if @project.machine_images_dataset.first(location_id: @location.id, name: mi_name)
              raise CloverError.new(400, "InvalidRequest", "Machine image with this name already exists in this location")
            end

            version = typecast_params.nonempty_str("version") || Time.now.utc.strftime("%Y%m%d%H%M%S")
            Validation.validate_machine_image_version_label(version)
            source_vm = source_vm_from_params

            DB.transaction do
              mi = MachineImage.create(
                name: mi_name,
                arch: source_vm.arch,
                project_id: @project.id,
                location_id: @location.id,
              )
              miv = assemble_machine_image_version(mi, version, source_vm)
              audit_log(mi, "create", [miv])
              Serializers::MachineImage.serialize(mi, {detailed: true})
            end
          end

          filter = {Sequel[:machine_image][:name] => mi_name}
        else
          filter = {Sequel[:machine_image][:id] => mi_id}
        end

        filter[:location_id] = @location.id
        mi = @project.machine_images_dataset.first(filter)
        check_found_object(mi)

        r.get true do
          authorize("MachineImage:view", mi)
          Serializers::MachineImage.serialize(mi, {detailed: true})
        end

        r.patch true do
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

          Serializers::MachineImage.serialize(mi.refresh, {detailed: true})
        end

        r.delete true do
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

        r.rename(mi, perm: "MachineImage:edit", serializer: Serializers::MachineImage, template_prefix: nil)

        r.on "version" do
          r.get true do
            authorize("MachineImage:view", mi)
            paginated_result(mi.versions_dataset.eager(:metal), Serializers::MachineImageVersion)
          end

          r.on(/([a-zA-Z0-9][a-zA-Z0-9._-]{0,63})/) do |version|
            r.post true do
              authorize("MachineImage:edit", mi)
              if mi.versions_dataset.first(version:)
                raise CloverError.new(400, "InvalidRequest", "Version #{version} already exists for this machine image")
              end
              source_vm = source_vm_from_params

              DB.transaction do
                miv = assemble_machine_image_version(mi, version, source_vm)
                audit_log(mi, "create_version", [miv])
                Serializers::MachineImageVersion.serialize(miv)
              end
            end

            r.delete true do
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
      end
    end
  end
end
