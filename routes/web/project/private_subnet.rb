# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "private-subnet") do |r|
    r.get true do
      @pss = ResourceManager.get_all(@project, @current_user, "private_subnet")

      view "private_subnet/index"
    end

    r.post true do
      Authorization.authorize(@current_user.id, "PrivateSubnet:create", @project.id)

      st = ResourceManager.post(r.params["location"], @project, r.params, "private_subnet")

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
