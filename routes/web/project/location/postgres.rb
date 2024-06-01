# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "postgres") do |r|
    r.on String do |pg_name|
      pg = @project.postgres_resources_dataset.where(location: @location).where { {Sequel[:postgres_resource][:name] => pg_name} }.first

      unless pg
        response.status = 404
        r.halt
      end

      route_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: @current_user, location: @location, resource: pg)

      r.get true do
        route_helper.get
      end

      r.delete true do
        route_helper.delete
      end

      r.on "firewall-rule" do
        r.post true do
          route_helper.post_firewall_rule
        end

        r.is String do |firewall_rule_ubid|
          r.delete true do
            route_helper.delete_firewall_rule(firewall_rule_ubid)
          end
        end
      end

      r.post "restore" do
        route_helper.restore
      end

      r.post "reset-superuser-password" do
        route_helper.reset_superuser_password
      end

      r.post "restart" do
        route_helper.restart
      end
    end
  end
end
