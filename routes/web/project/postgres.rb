# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "postgres") do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: current_user, location: nil, resource: nil)

    r.get true do
      pg_endpoint_helper.list
    end

    r.post true do
      # API request for resource creation already has location in the URL.
      # However for web endpoints the location is selected from the UI and
      # cannot be dynamically put to the form's action. due to csrf checks.
      # So we need to set the location here.
      pg_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
      pg_endpoint_helper.post(name: r.params["name"])
    end

    r.on "create" do
      r.get true do
        pg_endpoint_helper.view_create_page
      end
    end
  end
end
