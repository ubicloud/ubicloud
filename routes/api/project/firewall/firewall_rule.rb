# frozen_string_literal: true

class CloverApi
  hash_branch(:project_firewall_prefix, "firewall-rule") do |r|
    @serializer = Serializers::Api::FirewallRule

    r.post true do
      Authorization.authorize(@current_user.id, "Firewall:edit", @firewall.id)

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

      serialize(firewall_rule)
    end

    r.is String do |firewall_rule_ubid|
      firewall_rule = FirewallRule.from_ubid(firewall_rule_ubid)

      request.delete true do
        if firewall_rule
          Authorization.authorize(@current_user.id, "Firewall:edit", @firewall.id)
          @firewall.remove_firewall_rule(firewall_rule)
        end

        response.status = 204
        r.halt
      end
    end
  end
end
