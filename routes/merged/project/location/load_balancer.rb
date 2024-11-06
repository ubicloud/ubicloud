# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    lb_endpoint_helper = Routes::Common::LoadBalancerHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil)

    r.get api? do
      lb_endpoint_helper.list
    end

    r.on NAME_OR_UBID do |lb_name, lb_id|
      filter = if lb_name
        {Sequel[:load_balancer][:name] => lb_name}
      else
        {Sequel[:load_balancer][:id] => UBID.to_uuid(lb_id)}
      end

      filter[:private_subnet_id] = @project.private_subnets_dataset.where(location: @location).select(Sequel[:private_subnet][:id])
      lb = LoadBalancer.first(filter)
      lb_endpoint_helper.instance_variable_set(:@resource, lb)

      unless lb
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      r.on "attach-vm" do
        r.post true do
          lb_endpoint_helper.post_attach_vm
        end
      end

      r.on "detach-vm" do
        r.post true do
          lb_endpoint_helper.post_detach_vm
        end
      end

      r.get true do
        lb_endpoint_helper.get
      end

      r.delete true do
        lb_endpoint_helper.delete
      end

      r.patch api? do
        lb_endpoint_helper.patch
      end
    end
  end

  hash_branch(:api_project_location_prefix, "load-balancer", &branch)
  hash_branch(:project_location_prefix, "load-balancer", &branch)
end
