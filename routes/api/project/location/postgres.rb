# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "postgres") do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: @location, resource: nil)

    r.get true do
      pg_endpoint_helper.list
    end

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

    r.on "id" do
      r.on String do |pg_ubid|
        pg = PostgresResource.from_ubid(pg_ubid)

        if pg.nil? || pg.location != @location
          response.status = request.delete? ? 204 : 404
          request.halt
        end

        pg_endpoint_helper.instance_variable_set(:@resource, pg)
        add_routes(request, pg_endpoint_helper, routes)
      end
    end

    r.on String do |pg_name|
      r.post true do
        pg_endpoint_helper.post(name: pg_name)
      end

      pg = @project.postgres_resources_dataset.where(location: @location).where { {Sequel[:postgres_resource][:name] => pg_name} }.first
      if pg.nil?
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      pg_endpoint_helper.instance_variable_set(:@resource, pg)
      add_routes(request, pg_endpoint_helper, routes)
    end
  end
end
