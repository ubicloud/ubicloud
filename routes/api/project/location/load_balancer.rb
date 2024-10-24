# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "load-balancer") do |r|
    r.get true do
      Routes::Common::LoadBalancerHelper.new(app: self, request: r, user: @current_user, location: @location, resource: nil).list
    end

    pss = @project.private_subnets_dataset.where(location: @location).all

    r.on NAME_OR_UBID do |lb_name, lb_id|
      if lb_name
        lb = pss.flat_map { _1.load_balancers_dataset.where_all(Sequel[:load_balancer][:name] => lb_name) }.first
      else
        lb = LoadBalancer.from_ubid(lb_id)
        unless pss.any? { _1.load_balancers.map(&:ubid).include?(lb_id) }
          lb = nil
        end
      end

      handle_lb_requests(@current_user, lb)
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
