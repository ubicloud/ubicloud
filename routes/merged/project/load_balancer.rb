# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "load-balancer") do |r|
    r.get true do
      load_balancer_list
    end

    r.on web? do
      r.post true do
        load_balancer_post(r.params["name"])
      end

      r.get "create" do
        authorize("LoadBalancer:create", @project.id)
        authorized_subnets = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view").all
        @subnets = Serializers::PrivateSubnet.serialize(authorized_subnets)
        view "networking/load_balancer/create"
      end
    end
  end
end
