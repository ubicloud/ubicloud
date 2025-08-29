# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "private-subnet") do |r|
    r.get true do
      private_subnet_list
    end

    r.web do
      r.post true do
        handle_validation_failure("networking/private_subnet/create")
        check_visible_location
        private_subnet_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("PrivateSubnet:create", @project)
        view "networking/private_subnet/create"
      end
    end
  end
end
