# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "private-subnet") do |r|
    ps_endpoint_helper = Routes::Common::PrivateSubnetHelper.new(app: self, request: r, user: current_user, location: nil, resource: nil)

    r.get true do
      ps_endpoint_helper.list
    end

    r.post true do
      ps_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
      ps_endpoint_helper.post(r.params["name"])
    end

    r.on "create" do
      r.get true do
        ps_endpoint_helper.get_create
      end
    end
  end
end
