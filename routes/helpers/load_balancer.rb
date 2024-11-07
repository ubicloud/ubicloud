# frozen_string_literal: true

class Clover
  def load_balancer_list
    dataset = @project.load_balancers_dataset
    dataset = dataset.join(:private_subnet, id: Sequel[:load_balancer][:private_subnet_id]).where(location: @location).select_all(:load_balancer) if @location
    if api?
      result = dataset.authorized(current_account.id, "LoadBalancer:view").paginated_result(
        start_after: request.params["start_after"],
        page_size: request.params["page_size"],
        order_column: request.params["order_column"]
      )

      {
        items: Serializers::LoadBalancer.serialize(result[:records]),
        count: result[:count]
      }
    else
      @lbs = Serializers::LoadBalancer.serialize(dataset.authorized(current_account.id, "LoadBalancer:view").all, {include_path: true})
      view "networking/load_balancer/index"
    end
  end
end
