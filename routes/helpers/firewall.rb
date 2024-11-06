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

  def firewall_post(firewall_name)
    Authorization.authorize(current_account.id, "Firewall:create", @project.id)
    Validation.validate_name(firewall_name)
    @location ||= LocationNameConverter.to_internal_name(request.params["location"])

    description = if api?
      Validation.validate_request_body(request.body.read, [], ["description"])["description"] || ""
    else
      request.params["description"]
    end

    firewall = Firewall.create_with_id(
      name: firewall_name,
      description:,
      location: @location
    )
    firewall.associate_with_project(@project)

    if api?
      Serializers::Firewall.serialize(firewall)
    else
      private_subnet = PrivateSubnet.from_ubid(request.params["private-subnet-id"])
      firewall.associate_with_private_subnet(private_subnet) if private_subnet

      flash["notice"] = "'#{firewall_name}' is created"
      request.redirect "#{@project.path}#{firewall.path}"
    end
  end
end
