# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "private-subnet") do |r|
    @serializer = Serializers::Api::PrivateSubnet

    r.get true do
      result = @project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:view").eager(nics: [:private_subnet]).paginated_result(
        start_with: r.params["start_with"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end
  end
end
