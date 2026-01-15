# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "firewall") do |r|
    r.get true do
      dataset = firewall_list_dataset

      if api?
        firewall_list_api_response(dataset)
      else
        @firewalls = dataset.eager(:location).all
        view "networking/firewall/index"
      end
    end

    r.web do
      r.get "create" do
        authorize("Firewall:create", @project)
        view "networking/firewall/create"
      end

      r.post true do
        handle_validation_failure("networking/firewall/create")
        check_visible_location
        firewall_post(typecast_params.nonempty_str("name"))
      end
    end
  end
end
