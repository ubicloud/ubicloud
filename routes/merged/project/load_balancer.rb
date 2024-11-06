# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    lb_endpoint_helper = Routes::Common::LoadBalancerHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      lb_endpoint_helper.list
    end

    r.on api? do
      r.on String do |lb_name|
        r.post true do
          lb_endpoint_helper.post(name: lb_name)
        end
      end
    end

    r.post true do
      lb_endpoint_helper.post(name: r.params["name"])
    end

    r.on "create" do
      r.get true do
        lb_endpoint_helper.view_create_page
      end
    end
  end

  hash_branch(:api_project_prefix, "load-balancer", &branch)
  hash_branch(:project_prefix, "load-balancer", &branch)
end
