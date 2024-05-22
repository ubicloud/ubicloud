# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "private-subnet") do |r|
    r.get true do
      result = @project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:view").eager(nics: [:private_subnet]).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: Serializers::Common::PrivateSubnet.serialize(result[:records]),
        count: result[:count]
      }
    end
  end
end
