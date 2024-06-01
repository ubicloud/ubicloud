# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "postgres") do |r|
    route_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    r.get true do
      route_helper.list
    end
  end
end
