# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "vm") do |r|
    @serializer = Serializers::Web::Vm

    r.get true do
      @vms = serialize(@project.vms_dataset.authorized(@current_user.id, "Vm:view").eager(:semaphores, :assigned_vm_address, :vm_storage_volumes).order(Sequel.desc(:created_at)).all)

      view "vm/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Vm:create", @project.id)
      fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

      ps_id = r.params["private-subnet-id"].empty? ? nil : UBID.parse(r.params["private-subnet-id"]).to_uuid
      Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps_id)

      st = Prog::Vm::Nexus.assemble(
        r.params["public-key"],
        @project.id,
        name: r.params["name"],
        unix_user: r.params["user"],
        size: r.params["size"],
        location: r.params["location"],
        boot_image: r.params["boot-image"],
        private_subnet_id: ps_id,
        enable_ip4: r.params.key?("enable-ip4")
      )

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few minutes"

      r.redirect "#{@project.path}#{st.subject.path}"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "Vm:create", @project.id)
        @subnets = Serializers::Web::PrivateSubnet.serialize(@project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:view").all)

        # We use 1 month = 672 hours for conversion. Number of hours
        # in a month changes between 672 and 744, We are  also capping
        # billable hours to 672 while generating invoices. This ensures
        # that users won't see higher price in their invoice compared
        # to price calculator and also we charge same amount no matter
        # the number of days in a given month.
        types = ["VmCores", "IPAddress"].freeze
        @prices = BillingRate.rates.filter { types.include?(_1["resource_type"]) }
          .each_with_object(Hash.new { |h, k| h[k] = h.class.new(&h.default_proc) }) do |br, hash|
          hash[br["location"]][br["resource_type"]][br["resource_family"]] = {
            hourly: br["unit_price"].to_f * 60,
            monthly: br["unit_price"].to_f * 60 * 672
          }
        end
        @has_valid_payment_method = @project.has_valid_payment_method?

        view "vm/create"
      end
    end
  end
end
