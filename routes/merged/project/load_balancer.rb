# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get true do
      load_balancer_list
    end

    r.on api? do
      r.post String do |lb_name|
        load_balancer_post(lb_name)
      end
    end

    r.post true do
      load_balancer_post(r.params["name"])
    end

    r.get "create" do
      Authorization.authorize(current_account.id, "LoadBalancer:create", @project.id)
      authorized_subnets = @project.private_subnets_dataset.authorized(current_account.id, "PrivateSubnet:view").all
      @subnets = Serializers::PrivateSubnet.serialize(authorized_subnets)
      view "networking/load_balancer/create"
    end
  end

  hash_branch(:api_project_prefix, "load-balancer", &branch)
  hash_branch(:project_prefix, "load-balancer", &branch)
end
