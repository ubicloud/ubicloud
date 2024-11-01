# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    vm_endpoint_helper = Routes::Common::VmHelper.new(app: self, request: r, user: current_account, location: nil, resource: nil)

    r.get true do
      vm_endpoint_helper.list
    end

    r.on web? do
      r.post true do
        vm_endpoint_helper.instance_variable_set(:@location, LocationNameConverter.to_internal_name(r.params["location"]))
        vm_endpoint_helper.post(r.params["name"])
      end

      r.get "create" do
        Authorization.authorize(current_account.id, "Vm:create", @project.id)
        @subnets = Serializers::PrivateSubnet.serialize(@project.private_subnets_dataset.authorized(current_account.id, "PrivateSubnet:view").all)
        @prices = fetch_location_based_prices("VmCores", "VmStorage", "IPAddress")
        @has_valid_payment_method = @project.has_valid_payment_method?
        @default_location = @project.default_location
        @enabled_vm_sizes = Option::VmSizes.select { _1.visible && @project.quota_available?("VmCores", _1.vcpu / 2) }.map(&:name)

        view "vm/create"
      end
    end
  end

  hash_branch(:project_prefix, "vm", &branch)
  hash_branch(:api_project_prefix, "vm", &branch)
end
