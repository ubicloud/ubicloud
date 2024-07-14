# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "postgres") do |r|
    r.on String do |pg_name|
      pg = @project.postgres_resources_dataset.where(location: @location).where { {Sequel[:postgres_resource][:name] => pg_name} }.first

      unless pg
        response.status = 404
        r.halt
      end

      pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: @location, resource: pg)

      routes = [
        {method: :get, path: []},
        {method: :delete, path: []},
        {method: :post, path: ["firewall-rule"]},
        {method: :delete, path: ["firewall-rule", String]},
        {method: :post, path: ["metric-destination"]},
        {method: :delete, path: ["metric-destination", String]},
        {method: :post, path: ["restore"]},
        {method: :post, path: ["reset-superuser-password"]},
        {method: :post, path: ["restart"]}
      ]

      add_routes(r, pg_endpoint_helper, routes)
    end
  end
end
