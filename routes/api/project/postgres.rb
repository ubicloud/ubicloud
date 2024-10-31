# frozen_string_literal: true

class CloverApi
  hash_branch(:api_project_prefix, "postgres") do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      pg_endpoint_helper.list
    end
  end
end
