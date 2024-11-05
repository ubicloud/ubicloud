# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get true do
      private_subnet_list
    end

    r.on web? do
      r.post do
        @location = LocationNameConverter.to_internal_name(r.params["location"])
        private_subnet_post(r.params["name"])
      end

      r.get "create" do
        Authorization.authorize(current_account.id, "PrivateSubnet:create", @project.id)
        view "networking/private_subnet/create"
      end
    end
  end

  hash_branch(:api_project_prefix, "private-subnet", &branch)
  hash_branch(:project_prefix, "private-subnet", &branch)
end
