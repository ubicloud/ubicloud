# frozen_string_literal: true

class Clover
  def firewall_list_dataset
    dataset_authorize(@project.firewalls_dataset, "Firewall:view")
  end

  def firewall_list_api_response(dataset)
    dataset = dataset.where(location_id: @location.id) if @location
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

  def firewall_post
    authorize("Firewall:create", @project.id)

    @firewall.description ||= ""
    @firewall.save_changes

    if api?
      Serializers::Firewall.serialize(@firewall)
    else
      if (private_subnet = @private_subnet_dataset.where(location_id: @firewall.location_id).first(id: UBID.to_uuid(request.params["private_subnet_id"])))
        @firewall.associate_with_private_subnet(private_subnet)
      end

      flash["notice"] = "'#{@firewall.name}' is created"
      request.redirect "#{@project.path}#{@firewall.path}"
    end
  end
end
