# frozen_string_literal: true

class CloverApi
  hash_branch(:api_project_location_prefix, "load-balancer") do |r|
    r.get true do
      Routes::Common::LoadBalancerHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil).list
    end

    r.on NAME_OR_UBID do |lb_name, lb_id|
      filter = if lb_name
        {Sequel[:load_balancer][:name] => lb_name}
      else
        {Sequel[:load_balancer][:id] => UBID.to_uuid(lb_id)}
      end

      filter[:private_subnet_id] = @project.private_subnets_dataset.where(location: @location).select(Sequel[:private_subnet][:id])
      lb = LoadBalancer.first(filter)
      handle_lb_requests(current_account, lb)
    end
  end

  def handle_lb_requests(user, lb)
    unless lb
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    load_balancer_endpoint_helper = Routes::Common::LoadBalancerHelper.new(app: self, request: request, user: user, location: lb.private_subnet.location, resource: lb)

    request.get true do
      load_balancer_endpoint_helper.get
    end

    request.delete true do
      load_balancer_endpoint_helper.delete
    end

    request.patch true do
      load_balancer_endpoint_helper.patch
    end

    request.on "attach-vm" do
      request.post true do
        load_balancer_endpoint_helper.post_attach_vm
      end
    end

    request.on "detach-vm" do
      request.post true do
        load_balancer_endpoint_helper.post_detach_vm
      end
    end
  end
end
