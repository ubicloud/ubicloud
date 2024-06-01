# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "postgres") do |r|
    route_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    r.get true do
      route_helper.list
    end

    r.post true do
      route_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
      route_helper.post(name: r.params["name"])
    end

    r.on "create" do
      r.get true do
        route_helper.view_create_page
      end
    end
  end
end
