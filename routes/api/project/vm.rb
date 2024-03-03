# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "vm") do |r|
    @serializer = Serializers::Api::Vm

    r.get true do
      result = @project.vms_dataset.authorized(@current_user.id, "Vm:view").paginated_result(
        cursor: r.params["cursor"],
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
