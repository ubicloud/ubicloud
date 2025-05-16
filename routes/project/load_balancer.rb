# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "load-balancer") do |r|
    r.get true do
      load_balancer_list
    end

    r.web do
      r.post true do
        load_balancer_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("LoadBalancer:create", @project.id)
        @option_tree, @option_parents = generate_load_balancer_options
        view "networking/load_balancer/create"
      end
    end
  end
end
