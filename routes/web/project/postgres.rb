# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "postgres") do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    routes = [
      {method: :get, path: [], proc: proc { |pg_endpoint_helper, _| pg_endpoint_helper.list }},
      {method: :post, path: [], proc: proc { |pg_endpoint_helper, _|
                                        pg_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
                                        pg_endpoint_helper.post(r.params["name"])
                                      }},
      {method: :get, path: ["create"]}
    ]

    add_routes(r, pg_endpoint_helper, routes)
  end
end
