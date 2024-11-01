# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    vm_endpoint_helper = Routes::Common::VmHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      vm_endpoint_helper.list
    end

    r.on web? do
      r.post true do
        vm_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
        vm_endpoint_helper.post(r.params["name"])
      end

      r.on "create" do
        r.get true do
          vm_endpoint_helper.get_create
        end
      end
    end
  end

  hash_branch(:project_prefix, "vm", &branch)
  hash_branch(:api_project_prefix, "vm", &branch)
end
