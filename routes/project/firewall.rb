# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "firewall") do |r|
    r.get true do
      dataset = firewall_list_dataset

      if api?
        firewall_list_api_response(dataset)
      else
        authorized_firewalls = dataset.eager(:location).all
        @firewalls = Serializers::Firewall.serialize(authorized_firewalls, {include_path: true})

        view "networking/firewall/index"
      end
    end

    r.web do
      @firewall = Firewall.new(project_id: @project.id)
      @private_subnet_dataset = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:edit")

      r.get "create" do
        authorize("Firewall:create", @project.id)
        view "networking/firewall/create"
      end

      r.post true do
        forme_set(@firewall)
        @location = @firewall.location
        check_visible_location

        handle_validation_failure("networking/firewall/create") do
          firewall_post
        end
      end
    end
  end
end
