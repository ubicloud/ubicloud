# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "postgres") do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    add_routes(r, pg_endpoint_helper, [{method: :get, path: [], proc: proc { |pg_endpoint_helper, _| pg_endpoint_helper.list }}])
  end
end
