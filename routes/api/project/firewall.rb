# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "firewall") do |r|
    @serializer = Serializers::Api::Firewall

    r.get true do
      result = @project.firewalls_dataset.authorized(@current_user.id, "Firewall:view").eager(:firewall_rules).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: serialize(result[:records]),
        count: result[:count]
      }
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Firewall:create", @project.id)

      required_parameters = ["name"]
      allowed_optional_parameters = ["description"]
      request_body_params = Validation.validate_request_body(r.body.read, required_parameters, allowed_optional_parameters)
      Validation.validate_name(request_body_params["name"])

      firewall = Firewall.create_with_id(name: request_body_params["name"], description: request_body_params["description"] || "")
      firewall.associate_with_project(@project)

      serialize(firewall)
    end

    r.on String do |firewall_ubid|
      @firewall = Firewall.from_ubid(firewall_ubid)

      unless @firewall
        response.status = r.delete? ? 204 : 404
        r.halt
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Firewall:delete", @project.id)

        @firewall.dissociate_with_project(@project)
        @firewall.destroy

        response.status = 204
        r.halt
      end

      r.get true do
        Authorization.authorize(@current_user.id, "Firewall:view", @project.id)

        serialize(@firewall, :detailed)
      end

      r.post "attach-subnet" do
        Authorization.authorize(@current_user.id, "PrivateSubnet:edit", @project.id)

        required_parameters = ["private_subnet_id"]
        request_body_params = Validation.validate_request_body(r.body.read, required_parameters)

        private_subnet = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
        unless private_subnet
          fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" is not found"})
        end

        @firewall.associate_with_private_subnet(private_subnet)

        serialize(@firewall, :detailed)
      end

      r.post "detach-subnet" do
        Authorization.authorize(@current_user.id, "PrivateSubnet:edit", @project.id)

        required_parameters = ["private_subnet_id"]
        request_body_params = Validation.validate_request_body(r.body.read, required_parameters)

        private_subnet = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
        unless private_subnet
          fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" is not found"})
        end

        @firewall.disassociate_from_private_subnet(private_subnet)

        serialize(@firewall, :detailed)
      end

      r.hash_branches(:project_firewall_prefix)
    end
  end
end
