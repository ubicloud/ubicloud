# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "vm") do |r|
    r.get true do
      dataset = vm_list_dataset

      if api?
        vm_list_api_response(dataset)
      else
        @vms = dataset
          .eager(:semaphores, :assigned_vm_address, :vm_storage_volumes, :location)
          .reverse(:created_at)
          .all
        view "vm/index"
      end
    end

    r.web do
      r.post true do
        handle_validation_failure("vm/create")
        check_visible_location
        vm_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("Vm:create", @project)
        view "vm/create"
      end
    end
  end
end
