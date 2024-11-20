# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "firewall") do |r|
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
        authorize("Firewall:create", @project.id)
        authorized_subnets = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:edit").all
        @subnets = Serializers::PrivateSubnet.serialize(authorized_subnets)
        @default_location = @project.default_location
        view "networking/firewall/create"
      end

      r.post true do
        @location = LocationNameConverter.to_internal_name(r.params["location"])
        firewall_post(r.params["name"])
      end
    end
  end
end
