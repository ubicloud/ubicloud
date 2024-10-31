# frozen_string_literal: true

class Clover
  hash_branch(:api_project_prefix, "load-balancer") do |r|
    load_balancer_endpoint_helper = Routes::Common::LoadBalancerHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      load_balancer_endpoint_helper.list
    end

    r.on String do |lb_name|
      r.post true do
        load_balancer_endpoint_helper.post(name: lb_name)
      end
    end
  end
end
