# frozen_string_literal: true

class Clover
  def private_subnet_list
    if api?
      dataset = @project.private_subnets_dataset
      dataset = dataset.where(location: @location) if @location
      result = dataset.authorized(current_account.id, "PrivateSubnet:view").eager(nics: [:private_subnet]).paginated_result(
        start_after: request.params["start_after"],
        page_size: request.params["page_size"],
        order_column: request.params["order_column"]
      )

      {
        items: Serializers::PrivateSubnet.serialize(result[:records]),
        count: result[:count]
      }
    else
      @pss = Serializers::PrivateSubnet.serialize(@project.private_subnets_dataset.authorized(current_account.id, "PrivateSubnet:view").all, {include_path: true})
      view "networking/private_subnet/index"
    end
  end
end
