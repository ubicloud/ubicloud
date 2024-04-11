# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Api::Vm

    r.get true do
      result = @project.vms_dataset.where(location: @location).authorized(@current_user.id, "Vm:view").paginated_result(
        cursor: r.params["cursor"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.on "ubid" do
      r.on String do |vm_ubid|
        vm = Vm.from_ubid(vm_ubid)
        handle_vm_requests(@current_user, vm)
      end
    end

    r.on String do |vm_name|
      r.post true do
        Authorization.authorize(@current_user.id, "Vm:create", @project.id)
        fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

        required_parameters = ["public_key"]
        allowed_optional_parameters = ["size", "unix_user", "boot_image", "enable_ip4", "private_subnet_id"]

        request_body_params = Validation.validate_request_body(r.body.read, required_parameters, allowed_optional_parameters)

        # Generally parameter validation is handled in progs while creating resources.
        # Since Vm::Nexus both handles VM creation requests from user and also Postgres
        # service, moved the boot_image validation here to not allow users to pass
        # postgres image as boot image while creating a VM.
        if request_body_params["boot_image"]
          Validation.validate_boot_image(request_body_params["boot_image"])
        end

        if request_body_params["private_subnet_id"]
          ps = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
          unless ps
            fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" is not found"})
          end
          Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps.id)
          request_body_params["private_subnet_id"] = ps.id
        end

        st = Prog::Vm::Nexus.assemble(
          request_body_params["public_key"],
          @project.id,
          name: vm_name,
          location: @location,
          **request_body_params.except(*required_parameters).transform_keys(&:to_sym)
        )

        serialize(st.subject, :detailed)
      end

      vm = @project.vms_dataset.where(location: @location).where { {Sequel[:vm][:name] => vm_name} }.first
      handle_vm_requests(@current_user, vm)
    end
  end

  def handle_vm_requests(user, vm)
    unless vm
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.get true do
      Authorization.authorize(user.id, "Vm:view", vm.id)
      serialize(vm, :detailed)
    end

    request.delete true do
      Authorization.authorize(user.id, "Vm:delete", vm.id)
      vm.incr_destroy

      response.status = 204
      request.halt
    end

    request.on "firewall-rule" do
      request.post true do
        Authorization.authorize(user.id, "Vm:Firewall:edit", vm.id)

        required_parameters = ["cidr"]
        allowed_optional_parameters = ["port_range"]

        request_body_params = Validation.validate_request_body(request.body.read, required_parameters, allowed_optional_parameters)

        Validation.validate_cidr(request_body_params["cidr"])
        port_range = if request_body_params["port_range"].nil?
          [0, 65535]
        else
          request_body_params["port_range"] = Validation.validate_port_range(request_body_params["port_range"])
        end

        pg_range = Sequel.pg_range(port_range.first..port_range.last)

        vm.firewalls.first.insert_firewall_rule(request_body_params["cidr"], pg_range)

        serialize(vm, :detailed)
      end

      request.get true do
        Authorization.authorize(user.id, "Vm:Firewall:view", vm.id)
        Serializers::Api::Firewall.serialize(vm.firewalls.first)
      end

      request.is String do |firewall_rule_ubid|
        request.delete true do
          Authorization.authorize(user.id, "Vm:Firewall:edit", vm.id)

          if (fwr = FirewallRule.from_ubid(firewall_rule_ubid))
            fwr.destroy
            vm.incr_update_firewall_rules
          end

          response.status = 204
          request.halt
        end
      end
    end
  end
end
