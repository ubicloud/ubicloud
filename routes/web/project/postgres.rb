# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "postgres") do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    r.get true do
      pg_endpoint_helper.list
    end

    r.post true do
      pg_endpoint_helper.post
    end

    r.on "create" do
      r.get true do
        pg_endpoint_helper.view_create_page
      end
    end
  end
end
