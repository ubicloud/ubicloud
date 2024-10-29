# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "firewall") do |r|
    firewall_endpoint_helper = Routes::Common::FirewallHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      firewall_endpoint_helper.list
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(current_account.id, "Firewall:create", @project.id)
        authorized_subnets = @project.private_subnets_dataset.authorized(current_account.id, "PrivateSubnet:edit").all
        @subnets = Serializers::PrivateSubnet.serialize(authorized_subnets)
        @default_location = @project.default_location
        view "networking/firewall/create"
      end
    end

    r.post true do
      firewall_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
      firewall_endpoint_helper.post(r.params["name"])
    end
  end
end
