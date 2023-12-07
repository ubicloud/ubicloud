# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "vm") do |r|
    r.get true do
      @vms = ResourceManager.get_all(@project, @current_user, "vm")

      view "vm/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Vm:create", @project.id)
      fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

      ps_id = r.params["private-subnet-id"].empty? ? nil : UBID.parse(r.params["private-subnet-id"]).to_uuid
      Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps_id)

      params = r.params
      params["ps_id"] = ps_id
      st = ResourceManager.post(r.params["location"], @project, params, "vm")

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "#{@project.path}#{st.subject.path}"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "Vm:create", @project.id)
        @subnets = ResourceManager.get_all(@project, @current_user, "private_subnet")
        @prices = fetch_location_based_prices("VmCores", "IPAddress")
        @has_valid_payment_method = @project.has_valid_payment_method?

        view "vm/create"
      end
    end
  end
end
