# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "vm") do |r|
    r.get true do
      dataset = vm_list_dataset

      if api?
        vm_list_api_response(dataset)
      else
        @vms = Serializers::Vm.serialize(dataset.eager(:semaphores, :assigned_vm_address, :vm_storage_volumes, :location).reverse(:created_at).all, {include_path: true})
        view "vm/index"
      end
    end

    r.web do
      r.post true do
        check_visible_location
        vm_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("Vm:create", @project.id)
        @prices = fetch_location_based_prices("VmVCpu", "VmStorage", "IPAddress")
        @has_valid_payment_method = @project.has_valid_payment_method?
        @default_location = @project.default_location
        @enabled_vm_sizes = Option::VmSizes.select { it.visible && @project.quota_available?("VmVCpu", it.vcpus) }.map(&:name)
        @option_tree, @option_parents = generate_vm_options

        view "vm/create"
      end
    end
  end
end
