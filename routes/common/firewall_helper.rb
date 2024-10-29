# frozen_string_literal: true

class Routes::Common::FirewallHelper < Routes::Common::Base
  def list
    if @mode == AppMode::API
      dataset = project.firewalls_dataset
      dataset = dataset.where(location: @location) if @location
      result = dataset.authorized(@user.id, "Firewall:view").eager(:firewall_rules).paginated_result(
        start_after: @request.params["start_after"],
        page_size: @request.params["page_size"],
        order_column: @request.params["order_column"]
      )

      {
        items: Serializers::Firewall.serialize(result[:records]),
        count: result[:count]
      }
    else
      firewalls = Serializers::Firewall.serialize(project.firewalls_dataset.authorized(@user.id, "Firewall:view").all, {include_path: true})
      @app.instance_variable_set(:@firewalls, firewalls)

      @app.view "networking/firewall/index"
    end
  end
end
