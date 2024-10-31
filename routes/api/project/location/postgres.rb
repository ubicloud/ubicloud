# frozen_string_literal: true

class CloverApi
  hash_branch(:api_project_location_prefix, "postgres") do |r|
    pg_endpoint_helper = Routes::Common::PostgresHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil)

    r.get true do
      pg_endpoint_helper.list
    end

    r.on NAME_OR_UBID do |pg_name, pg_ubid|
      if pg_name
        r.post true do
          pg_endpoint_helper.post(name: pg_name)
        end

        filter = {Sequel[:postgres_resource][:name] => pg_name}
      else
        filter = {Sequel[:postgres_resource][:id] => UBID.to_uuid(pg_ubid)}
      end

      filter[:location] = @location
      pg = @project.postgres_resources_dataset.first(filter)
      pg_endpoint_helper.instance_variable_set(:@resource, pg)
      handle_pg_requests(pg_endpoint_helper)
    end

    # 204 response for invalid names
    r.is String do |pg_name|
      r.post do
        pg_endpoint_helper.post(name: pg_name)
      end

      r.delete do
        response.status = 204
        nil
      end
    end
  end

  def handle_pg_requests(pg_endpoint_helper)
    unless pg_endpoint_helper.instance_variable_get(:@resource)
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.get true do
      pg_endpoint_helper.get
    end

    request.delete true do
      pg_endpoint_helper.delete
    end

    request.on "firewall-rule" do
      request.post true do
        pg_endpoint_helper.post_firewall_rule
      end

      request.get true do
        pg_endpoint_helper.get_firewall_rule
      end

      request.is String do |firewall_rule_ubid|
        request.delete true do
          pg_endpoint_helper.delete_firewall_rule(firewall_rule_ubid)
        end
      end
    end

    request.on "metric-destination" do
      request.post true do
        pg_endpoint_helper.post_metric_destination
      end

      request.is String do |metric_destination_ubid|
        request.delete true do
          pg_endpoint_helper.delete_metric_destination(metric_destination_ubid)
        end
      end
    end

    request.post "restore" do
      pg_endpoint_helper.restore
    end

    request.post "reset-superuser-password" do
      pg_endpoint_helper.reset_superuser_password
    end

    request.post "failover" do
      pg_endpoint_helper.failover
    end
  end
end
