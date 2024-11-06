# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get true do
      dataset = firewall_list_dataset

      if api?
        firewall_list_api_response(dataset)
      else
        authorized_firewalls = dataset.all
        @firewalls = Serializers::Firewall.serialize(authorized_firewalls, {include_path: true})

        view "networking/firewall/index"
      end
    end

    r.on web? do
      r.get "create" do
        Authorization.authorize(current_account.id, "Firewall:create", @project.id)
        authorized_subnets = @project.private_subnets_dataset.authorized(current_account.id, "PrivateSubnet:edit").all
        @subnets = Serializers::PrivateSubnet.serialize(authorized_subnets)
        @default_location = @project.default_location
        view "networking/firewall/create"
      end

      r.post true do
        firewall_post(r.params["name"])
      end
    end
  end

  hash_branch(:project_prefix, "firewall", &branch)
  hash_branch(:api_project_prefix, "firewall", &branch)
end
