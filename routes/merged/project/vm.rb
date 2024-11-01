# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get true do
      dataset = vm_list_dataset

      if api?
        vm_list_api_response(dataset)
      else
        @vms = Serializers::Vm.serialize(dataset.eager(:semaphores, :assigned_vm_address, :vm_storage_volumes).reverse(:created_at).all, {include_path: true})
        view "vm/index"
      end
    end

    r.on web? do
      r.post true do
        @location = LocationNameConverter.to_internal_name(r.params["location"])
        vm_post(r.params["name"])
      end

      r.get "create" do
        Authorization.authorize(current_account.id, "Vm:create", @project.id)
        @subnets = Serializers::PrivateSubnet.serialize(@project.private_subnets_dataset.authorized(current_account.id, "PrivateSubnet:view").all)
        @prices = fetch_location_based_prices("VmCores", "VmStorage", "IPAddress")
        @has_valid_payment_method = @project.has_valid_payment_method?
        @default_location = @project.default_location
        @enabled_vm_sizes = Option::VmSizes.select { _1.visible && @project.quota_available?("VmCores", _1.vcpu / 2) }.map(&:name)

        view "vm/create"
      end
    end
  end

  hash_branch(:project_prefix, "vm", &branch)
  hash_branch(:api_project_prefix, "vm", &branch)
end
