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
      r.get "create" do
        authorize("Firewall:create", @project.id)
        @option_tree, @option_parents = generate_firewall_options
        @default_location = @project.default_location
        view "networking/firewall/create"
      end

      r.post true do
        next unless (@location = Location[typecast_params.nonempty_str("location")])
        firewall_post(typecast_params.nonempty_str("name"))
      end
    end
  end
end
