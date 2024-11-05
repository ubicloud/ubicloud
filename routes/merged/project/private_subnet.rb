# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    ps_endpoint_helper = Routes::Common::PrivateSubnetHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      ps_endpoint_helper.list
    end

    r.on web? do
      r.post do
        ps_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
        ps_endpoint_helper.post(r.params["name"])
      end

      r.get "create" do
        ps_endpoint_helper.get_create
      end
    end
  end

  hash_branch(:api_project_prefix, "private-subnet", &branch)
  hash_branch(:project_prefix, "private-subnet", &branch)
end
