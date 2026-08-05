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
        view "vm/create"
      end
    end
  end
end
