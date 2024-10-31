# frozen_string_literal: true

class Clover
  hash_branch(:api_project_prefix, "firewall") do |r|
    r.get true do
      result = @project.firewalls_dataset.authorized(current_account.id, "Firewall:view").eager(:firewall_rules).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: Serializers::Firewall.serialize(result[:records]),
        count: result[:count]
      }
    end
  end
end
