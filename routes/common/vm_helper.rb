# frozen_string_literal: true

class Routes::Common::VmHelper < Routes::Common::Base
  def list
    if @mode == AppMode::API
      dataset = project.vms_dataset
      dataset = dataset.where(location: @location) if @location
      result = dataset.authorized(@user.id, "Vm:view").paginated_result(
        start_after: @request.params["start_after"],
        page_size: @request.params["page_size"],
        order_column: @request.params["order_column"]
      )

      {
        items: Serializers::Vm.serialize(result[:records]),
        count: result[:count]
      }
    else
      vms = Serializers::Vm.serialize(project.vms_dataset.authorized(@user.id, "Vm:view").eager(:semaphores, :assigned_vm_address, :vm_storage_volumes).order(Sequel.desc(:created_at)).all, {include_path: true})
      @app.instance_variable_set(:@vms, vms)

      @app.view "vm/index"
    end
  end

  def post(name)
    Authorization.authorize(@user.id, "Vm:create", project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless project.has_valid_payment_method?
    if @mode == AppMode::API
      required_parameters = ["public_key"]
      allowed_optional_parameters = ["size", "storage_size", "unix_user", "boot_image", "enable_ip4", "private_subnet_id"]

      request_body_params = Validation.validate_request_body(params, required_parameters, allowed_optional_parameters)

      # Generally parameter validation is handled in progs while creating resources.
      # Since Vm::Nexus both handles VM creation requests from user and also Postgres
      # service, moved the boot_image validation here to not allow users to pass
      # postgres image as boot image while creating a VM.
      if request_body_params["boot_image"]
        Validation.validate_boot_image(request_body_params["boot_image"])
      end

      # Same as above, moved the size validation here to not allow users to
      # pass gpu instance while creating a VM.
      if request_body_params["size"]
        parsed_size = Validation.validate_vm_size(request_body_params["size"], only_visible: true)
      end

      if request_body_params["private_subnet_id"]
        ps = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
        unless ps && ps.location == @location
          fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" is not found in the location \"#{LocationNameConverter.to_display_name(@location)}\""})
        end
        Authorization.authorize(@user.id, "PrivateSubnet:view", ps.id)
        request_body_params["private_subnet_id"] = ps.id
      end

      if request_body_params["storage_size"]
        storage_size = Validation.validate_vm_storage_size(request_body_params["size"], request_body_params["storage_size"])
        request_body_params["storage_volumes"] = [{size_gib: storage_size, encrypted: true}]
        request_body_params.delete("storage_size")
      end

      requested_vm_core_count = parsed_size.nil? ? 1 : parsed_size.vcpu / 2
      Validation.validate_core_quota(project, "VmCores", requested_vm_core_count)

      st = Prog::Vm::Nexus.assemble(
        request_body_params["public_key"],
        project.id,
        name: name,
        location: @location,
        **request_body_params.except(*required_parameters).transform_keys(&:to_sym)
      )

      Serializers::Vm.serialize(st.subject, {detailed: true})
    else
      ps_id = @request.params["private-subnet-id"].empty? ? nil : UBID.parse(@request.params["private-subnet-id"]).to_uuid
      Authorization.authorize(@user.id, "PrivateSubnet:view", ps_id)

      Validation.validate_boot_image(@request.params["boot-image"])
      parsed_size = Validation.validate_vm_size(@request.params["size"], only_visible: true)
      location = LocationNameConverter.to_internal_name(@request.params["location"])
      storage_size = Validation.validate_vm_storage_size(@request.params["size"], @request.params["storage_size"])

      requested_vm_core_count = parsed_size.vcpu / 2
      Validation.validate_core_quota(project, "VmCores", requested_vm_core_count)

      st = Prog::Vm::Nexus.assemble(
        @request.params["public-key"],
        project.id,
        name: name,
        unix_user: @request.params["user"],
        size: @request.params["size"],
        storage_volumes: [{size_gib: storage_size, encrypted: true}],
        location: location,
        boot_image: @request.params["boot-image"],
        private_subnet_id: ps_id,
        enable_ip4: @request.params.key?("enable-ip4")
      )

      flash["notice"] = "'#{name}' will be ready in a few minutes"

      @request.redirect "#{project.path}#{st.subject.path}"
    end
  end

  def get
    Authorization.authorize(@user.id, "Vm:view", @resource.id)
    if @mode == AppMode::API
      Serializers::Vm.serialize(@resource, {detailed: true})
    else
      @app.instance_variable_set(:@vm, Serializers::Vm.serialize(@resource, {detailed: true}))
      @app.view "vm/show"
    end
  end

  def delete
    Authorization.authorize(@user.id, "Vm:delete", @resource.id)
    @resource.incr_destroy
    if @mode == AppMode::API
      response.status = 204
      @request.halt
    else
      {message: "Deleting #{@resource.name}"}.to_json
    end
  end

  def get_create
    Authorization.authorize(@user.id, "Vm:create", project.id)
    @app.instance_variable_set(:@subnets, Serializers::PrivateSubnet.serialize(project.private_subnets_dataset.authorized(@user.id, "PrivateSubnet:view").all))
    @app.instance_variable_set(:@prices, @app.fetch_location_based_prices("VmCores", "VmStorage", "IPAddress"))
    @app.instance_variable_set(:@has_valid_payment_method, project.has_valid_payment_method?)
    @app.instance_variable_set(:@default_location, project.default_location)
    @app.instance_variable_set(:@enabled_vm_sizes, Option::VmSizes.select { _1.visible && project.quota_available?("VmCores", _1.vcpu / 2) }.map(&:name))

    @app.view "vm/create"
  end
end
