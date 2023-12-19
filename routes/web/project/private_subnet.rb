# frozen_string_literal: true

class CloverWeb
  # Define rpc functions at the top
  CloverBase.run_on_all_locations :list_private_subnet do |project, current_user|
    project.private_subnets_dataset.authorized(current_user.id, "PrivateSubnet:view").all
  end

  CloverBase.run_on_location :post_private_subnet do |project, params|
    Prog::Vnet::SubnetNexus.assemble(
      project.id,
      name: params["name"],
      location: params["location"]
    )
  end

  hash_branch(:project_prefix, "private-subnet") do |r|
    @serializer = Serializers::Web::PrivateSubnet

    r.get true do
      @pss = serialize(list_private_subnet(@project, @current_user))

      view "private_subnet/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)

      st = post_private_subnet(r.params["location"], @project, r.params)

      flash["notice"] = "'#{r.params["name"]}' will be ready in a few seconds"

      r.redirect "#{@project.path}#{st.subject.path}"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)

        view "private_subnet/create"
      end
    end
  end
end
