# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "vm") do |r|
    r.get true do
      vm_list
    end

    r.web do
      r.post true do
        handle_validation_failure("vm/create")
        check_visible_location
        vm_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("Vm:create", @project)
        if typecast_params.bool("show_gpu") && !@project.get_ff_gpu_vm
          view "vm/create_gpu_request_access"
        else
          view "vm/create"
        end
      end
    end
  end
end
