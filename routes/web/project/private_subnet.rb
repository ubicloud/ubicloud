# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "private-subnet") do |r|
    r.get true do
      @pss = Serializers::PrivateSubnet.serialize(@project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:view").all, {include_path: true})

      view "networking/private_subnet/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)
      location = LocationNameConverter.to_internal_name(r.params["location"])

      st = Prog::Vnet::SubnetNexus.assemble(
        @project.id,
        name: r.params["name"],
        location: location
      )

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few seconds"

      r.redirect "#{@project.path}#{PrivateSubnet[st.id].path}"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)

        view "networking/private_subnet/create"
      end
    end
  end
end
