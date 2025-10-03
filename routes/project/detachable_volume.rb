# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "detachable-volume") do |r|
    r.get true do
      @detachable_volumes = detachable_volume_list_dataset.reverse(:created_at).all
      view "storage/index"
    end

    r.web do
      r.post true do
        handle_validation_failure("storage/create")
        name = typecast_params.nonempty_str!("name")
        size_gib = typecast_params.pos_int!("size_gib")
        detachable_volume_post(name, size_gib)
      end

      r.get "create" do
        authorize("DetachableVolume:create", @project.id)
        unit_price = BillingRate.unit_price_from_resource_properties("VmStorage", "standard", "hetzner-fsn1")
        @price_per_gib = unit_price.to_f * 60 * 672
        view "storage/create"
      end

      r.on DETACHABLE_VOLUME_NAME_OR_UBID do |dv_name, dv_ubid|
        filter = dv_name ? {name: dv_name} : {id: UBID.to_uuid(dv_ubid)}
        @detachable_volume = dv = @project.detachable_volumes_dataset.first(filter)
        check_found_object(dv)

        r.get true do
          authorize("DetachableVolume:view", dv.id)
          r.redirect dv, "/overview" if web?
        end

        r.delete true do
          authorize("DetachableVolume:delete", dv.id)
          DB.transaction do
            dv.incr_destroy
            audit_log(dv, "destroy")
          end
          204
        end

        r.rename dv, perm: "DetachableVolume:edit", serializer: Serializers::DetachableVolume, template_prefix: "storage"

        r.show_object(dv, actions: %w[overview settings], perm: "DetachableVolume:view", template: "storage/show")
      end
    end
  end
end
