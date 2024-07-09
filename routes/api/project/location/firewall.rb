# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "firewall") do |r|
    r.get true do
      result = @project.firewalls_dataset.where(location: @location).authorized(@current_user.id, "Firewall:view").eager(:firewall_rules).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: Serializers::Firewall.serialize(result[:records]),
        count: result[:count]
      }
    end

    r.on "id" do
      r.on String do |firewall_id|
        @firewall = Firewall.from_ubid(firewall_id)

        if @firewall&.location != @location
          @firewall = nil
        end

        handle_firewall_requests(@current_user, @firewall, @location)
      end
    end

    r.is String do |firewall_name|
      r.post true do
        Authorization.authorize(@current_user.id, "Firewall:create", @project.id)

        allowed_optional_parameters = ["description"]
        request_body_params = Validation.validate_request_body(r.body.read, [], allowed_optional_parameters)
        Validation.validate_name(firewall_name)

        firewall = Firewall.create_with_id(name: firewall_name, location: @location, description: request_body_params["description"] || "")
        firewall.associate_with_project(@project)

        Serializers::Firewall.serialize(firewall)
      end

      @firewall = @project.firewalls_dataset.where(location: @location).where { {Sequel[:firewall][:name] => firewall_name} }.first
      handle_firewall_requests(@current_user, @firewall, @location)
    end
  end

  def handle_firewall_requests(user, firewall, location)
    unless firewall
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.delete true do
      Authorization.authorize(user.id, "Firewall:delete", @project.id)

      firewall.destroy

      response.status = 204
      request.halt
    end

    request.get true do
      Authorization.authorize(user.id, "Firewall:view", @project.id)

      Serializers::Firewall.serialize(firewall, {detailed: true})
    end

    request.post "attach-subnet" do
      Authorization.authorize(user.id, "PrivateSubnet:edit", @project.id)

      required_parameters = ["private_subnet_id"]
      request_body_params = Validation.validate_request_body(request.body.read, required_parameters)

      private_subnet = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
      unless private_subnet && private_subnet.location == @location
        fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" and the location \"#{location}\" is not found"})
      end

      firewall.associate_with_private_subnet(private_subnet)

      Serializers::Firewall.serialize(firewall, {detailed: true})
    end

    request.post "detach-subnet" do
      Authorization.authorize(@current_user.id, "PrivateSubnet:edit", @project.id)

      required_parameters = ["private_subnet_id"]
      request_body_params = Validation.validate_request_body(request.body.read, required_parameters)

      private_subnet = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
      unless private_subnet && private_subnet.location == @location
        fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" and the location \"#{location}\" is not found"})
      end

      firewall.disassociate_from_private_subnet(private_subnet)

      Serializers::Firewall.serialize(firewall, {detailed: true})
    end

    request.hash_branches(:project_location_firewall_prefix)
  end
end
