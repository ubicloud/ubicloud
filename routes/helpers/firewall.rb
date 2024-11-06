# frozen_string_literal: true

class Clover
  def firewall_list_dataset
    @project.firewalls_dataset.authorized(current_account.id, "Firewall:view")
  end

  def firewall_list_api_response(dataset)
    dataset = dataset.where(location: @location) if @location
    result = dataset.eager(:firewall_rules).paginated_result(
      start_after: request.params["start_after"],
      page_size: request.params["page_size"],
      order_column: request.params["order_column"]
    )

    {
      items: Serializers::Firewall.serialize(result[:records]),
      count: result[:count]
    }
  end
end
