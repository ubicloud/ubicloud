# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "postgres") do |r|
    route_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: @location, resource: nil)

    r.get true do
      route_helper.list
    end

    r.on "id" do
      r.on String do |pg_ubid|
        pg = PostgresResource.from_ubid(pg_ubid)

        if pg&.location != @location
          pg = nil
        end

        route_helper.instance_variable_set(:@resource, pg)
        handle_pg_requests(pg, route_helper)
      end
    end

    r.on String do |pg_name|
      r.post true do
        route_helper.post(name: pg_name)
      end

      pg = @project.postgres_resources_dataset.where(location: @location).where { {Sequel[:postgres_resource][:name] => pg_name} }.first
      route_helper.instance_variable_set(:@resource, pg)
      handle_pg_requests(pg, route_helper)
    end
  end

  def handle_pg_requests(pg, route_helper)
    unless pg
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.get true do
      route_helper.get
    end

    request.delete true do
      route_helper.delete
    end

    request.on "firewall-rule" do
      request.post true do
        route_helper.post_firewall_rule
      end

      request.get true do
        route_helper.get_firewall_rule
      end

      request.is String do |firewall_rule_ubid|
        request.delete true do
          route_helper.delete_firewall_rule(firewall_rule_ubid)
        end
      end
    end

    request.post "restore" do
      route_helper.restore
    end

    request.post "reset-superuser-password" do
      route_helper.reset_superuser_password
    end
  end
end
