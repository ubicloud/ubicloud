# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Api::Vm

    r.get true do
      cursor = r.params["cursor"]
      page_size = r.params["page-size"]
      order_column = r.params["order-column"] ||= "id"

      result = @project.vms_dataset.where(location: @location).authorized(@current_user.id, "Vm:view").order(order_column.to_sym).paginated_result(cursor, page_size, order_column)

      {
        values: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.is String do |vm_name|
      r.post true do
        Authorization.authorize(@current_user.id, "Vm:create", @project.id)
        fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

        request_body_params = JSON.parse(request.body.read)

        st = Prog::Vm::Nexus.assemble(
          request_body_params["public_key"],
          @project.id,
          name: vm_name,
          unix_user: request_body_params["unix_user"],
          size: request_body_params["size"],
          location: @location,
          boot_image: request_body_params["boot_image"],
          enable_ip4: !!request_body_params["enable_ip4"]
        )

        serialize(st.subject)
        r.halt
      end

      vm = @project.vms_dataset.where(location: @location).where { {Sequel[:vm][:name] => vm_name} }.first

      r.get true do
        unless ps
          response.status = 404
          r.halt
        end

        Authorization.authorize(@current_user.id, "Vm:view", vm.id)

        serialize(vm)
      end

      r.delete true do
        if vm
          Authorization.authorize(@current_user.id, "Vm:delete", vm.id)
          vm.incr_destroy
        end

        response.status = 204
        r.halt
      end
    end
  end
end
