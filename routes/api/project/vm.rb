# frozen_string_literal: true

class Clover
  hash_branch(:api_project_prefix, "vm") do |r|
    vm_endpoint_helper = Routes::Common::VmHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      vm_endpoint_helper.list
    end
  end
end
