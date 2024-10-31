# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "load-balancer") do |r|
    r.on String do |lb_name|
      pss = @project.private_subnets_dataset.where(location: @location).all
      lb = pss.flat_map { _1.load_balancers_dataset.where { {Sequel[:load_balancer][:name] => lb_name} }.all }.first

      unless lb
        response.status = r.delete? ? 204 : 404
        r.halt
      end

      load_balancer_endpoint_helper = Routes::Common::LoadBalancerHelper.new(app: self, request: r, user: current_account, resource: lb, location: nil)

      r.get true do
        load_balancer_endpoint_helper.get
      end

      r.delete true do
        load_balancer_endpoint_helper.delete
      end

      r.on "attach-vm" do
        r.post true do
          load_balancer_endpoint_helper.post_attach_vm
        end
      end

      r.on "detach-vm" do
        r.post true do
          load_balancer_endpoint_helper.post_detach_vm
        end
      end
    end
  end
end
