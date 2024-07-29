# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "vm") do |r|
    vm_endpoint_helper = Routes::Common::VmHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    r.get true do
      vm_endpoint_helper.list
    end
  end
end
