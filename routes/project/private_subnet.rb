# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "private-subnet") do |r|
    r.get true do
      private_subnet_list
    end

    r.web do
      r.post do
        @location = LocationNameConverter.to_internal_name(r.params["location"])
        private_subnet_post(r.params["name"])
      end

      r.get "create" do
        authorize("PrivateSubnet:create", @project.id)
        @option_tree, @option_parents = generate_private_subnet_options
        view "networking/private_subnet/create"
      end
    end
  end
end
