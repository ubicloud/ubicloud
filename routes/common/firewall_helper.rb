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

  def post(name)
    Authorization.authorize(@user.id, "Firewall:create", project.id)

    allowed_optional_parameters = ["description", "private_subnet_id"]
    request_body_params = Validation.validate_request_body(params, [], allowed_optional_parameters)

    Validation.validate_name(name)
    
    firewall = Firewall.create_with_id(
      name: name,
      description: request_body_params["description"],
      location: @location
    )
    firewall.associate_with_project(@project)

    ps = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"]) if request_body_params["private_subnet_id"]
    firewall.associate_with_private_subnet(ps) if ps

    if @mode == AppMode::API
      Serializers::Firewall.serialize(firewall)
    else
      flash["notice"] = "'#{name}' is created"
      @request.redirect "#{@project.path}#{Firewall[fw.id].path}"
    end
  end
end
