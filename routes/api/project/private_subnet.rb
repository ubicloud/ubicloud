# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "private-subnet") do |r|
    ps_endpoint_helper = Routes::Common::PrivateSubnetHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    r.get true do
      ps_endpoint_helper.list
    end
  end
end
