# frozen_string_literal: true

class Clover
  def vm_list_dataset
    @project.vms_dataset.authorized(current_account.id, "Vm:view")
  end

  def vm_list_api_response(dataset)
    dataset = dataset.where(location: @location) if @location
    result = dataset.paginated_result(
      start_after: request.params["start_after"],
      page_size: request.params["page_size"],
      order_column: request.params["order_column"]
    )

    {
      items: Serializers::Vm.serialize(result[:records]),
      count: result[:count]
    }
  end
end
