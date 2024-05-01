# frozen_string_literal: true

class CloverApi
  hash_branch(:project_firewall_prefix, "firewall-rule") do |r|
    @serializer = Serializers::Api::FirewallRule

    r.get true do
      result = @firewall.firewall_rules_dataset.authorized(@current_user.id, "FirewallRule:view").paginated_result(
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
      Authorization.authorize(@current_user.id, "FirewallRule:create", @firewall.id)

      required_parameters = ["cidr"]
      allowed_optional_parameters = ["port_range"]

      request_body_params = Validation.validate_request_body(request.body.read, required_parameters, allowed_optional_parameters)

      parsed_cidr = Validation.validate_cidr(request_body_params["cidr"])
      port_range = if request_body_params["port_range"].nil?
        [0, 65535]
      else
        request_body_params["port_range"] = Validation.validate_port_range(request_body_params["port_range"])
      end

      pg_range = Sequel.pg_range(port_range.first..port_range.last)

      firewall_rule = @firewall.insert_firewall_rule(parsed_cidr.to_s, pg_range)
      firewall_rule.associate_with_project(@project)

      serialize(firewall_rule)
    end

    r.is String do |firewall_rule_ubid|
      firewall_rule = FirewallRule.from_ubid(firewall_rule_ubid)

      unless firewall_rule
        response.status = r.delete? ? 204 : 404
        r.halt
      end

      request.delete true do
        Authorization.authorize(@current_user.id, "FirewallRule:delete", firewall_rule.id)
        @firewall.remove_firewall_rule(firewall_rule)
        firewall_rule.dissociate_with_project(@project)

        response.status = 204
        r.halt
      end

      request.get true do
        Authorization.authorize(@current_user.id, "FirewallRule:view", firewall_rule.id)
        serialize(firewall_rule)
      end
    end
  end
end
