# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      pg_endpoint_helper.list
    end

    r.on web? do
      r.post true do
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

  hash_branch(:api_project_prefix, "postgres", &branch)
  hash_branch(:project_prefix, "postgres", &branch)
end
