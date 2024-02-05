# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "vm") do |r|
    @serializer = Serializers::Api::Vm

    r.get true do
      cursor = r.params["cursor"]
      page_size = r.params["page-size"]
      order_column = r.params["order-column"] ||= "id"

      result = @project.vms_dataset.authorized(@current_user.id, "Vm:view").order(order_column.to_sym).paginated_result(cursor, page_size, order_column)

      {
        values: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end
  end
end
