# frozen_string_literal: true

class CloverWeb
  CloverBase.run_on_all_locations :list_vm do |project, current_user|
    project.vms_dataset.authorized(current_user.id, "Vm:view").eager(:semaphores, :assigned_vm_address, :vm_storage_volumes).order(Sequel.desc(:created_at)).all
  end

  CloverBase.run_on_all_locations :list_private_subnet do |project, current_user|
    project.private_subnets_dataset.authorized(current_user.id, "PrivateSubnet:view").all
  end

  CloverBase.run_on_location :post_vm do |project, params|
    Prog::Vm::Nexus.assemble(
      params["public-key"],
      project.id,
      name: params["name"],
      unix_user: params["user"],
      size: params["size"],
      location: params["location"],
      boot_image: params["boot-image"],
      private_subnet_id: params["ps_id"],
      enable_ip4: params.key?("enable-ip4")
    )
  end

  hash_branch(:project_prefix, "vm") do |r|
    @serializer = Serializers::Web::Vm

    r.get true do
      @vms = serialize(list_vm(@project, @current_user))

      view "vm/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Vm:create", @project.id)
      fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

      ps_id = r.params["private-subnet-id"].empty? ? nil : UBID.parse(r.params["private-subnet-id"]).to_uuid
      r.params["ps_id"] = ps_id
      Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps_id)

      post_vm(r.params["location"], @project, r.params)

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "#{@project.path}/vm"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "Vm:create", @project.id)
        @subnets = Serializers::Web::PrivateSubnet.serialize(list_private_subnet(@project, @current_user))
        @prices = fetch_location_based_prices("VmCores", "IPAddress")
        @has_valid_payment_method = @project.has_valid_payment_method?

        view "vm/create"
      end
    end
  end
end
