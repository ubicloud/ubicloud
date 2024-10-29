# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "firewall") do |r|
    firewall_endpoint_helper = Routes::Common::FirewallHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      firewall_endpoint_helper.list
    end
  end
end
