# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "postgres") do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: @location, resource: nil)

    add_routes(r, pg_endpoint_helper, [{method: :get, path: [], proc: proc { |pg_endpoint_helper, _| pg_endpoint_helper.list }}])

    routes = [
      {method: :get, path: []},
      {method: :delete, path: []},
      {method: :post, path: ["firewall-rule"]},
      {method: :get, path: ["firewall-rule"]},
      {method: :delete, path: ["firewall-rule", String]},
      {method: :post, path: ["metric-destination"]},
      {method: :delete, path: ["metric-destination", String]},
      {method: :post, path: ["restore"]},
      {method: :post, path: ["reset-superuser-password"]},
      {method: :post, path: ["restart"]},
      {method: :post, path: ["failover"]}
    ]

    [{all: ["id", String]}, String].each_with_index do |path, index|
      r.on path do |pg_identifier|
        if index == 0
          pg = PostgresResource.from_ubid(pg_identifier)
        else
          routes << {method: :post, path: [], proc: proc { |pg_endpoint_helper, _| pg_endpoint_helper.post(pg_identifier) }}
          pg = @project.postgres_resources_dataset.where(location: @location).where { {Sequel[:postgres_resource][:name] => pg_identifier} }.first
        end

        if (pg.nil? || pg.location != @location) && !(index == 1 && request.post? && request.remaining_path == "")
          response.status = request.delete? ? 204 : 404
          request.halt
        end

        pg_endpoint_helper.instance_variable_set(:@resource, pg)
        add_routes(request, pg_endpoint_helper, routes)
      end
    end
  end
end
