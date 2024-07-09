# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "firewall") do |r|
    r.get true do
      authorized_firewalls = @project.firewalls_dataset.authorized(@current_user.id, "Firewall:view").all
      @firewalls = Serializers::Firewall.serialize(authorized_firewalls, {include_path: true})

      view "networking/firewall/index"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "Firewall:create", @project.id)
        authorized_subnets = @project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:edit").all
        @subnets = Serializers::PrivateSubnet.serialize(authorized_subnets)
        @default_location = @project.default_location
        view "networking/firewall/create"
      end
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Firewall:create", @project.id)
      Validation.validate_name(r.params["name"])
      location = LocationNameConverter.to_internal_name(r.params["location"])

      fw = Firewall.create_with_id(
        name: r.params["name"],
        description: r.params["description"],
        location: location
      )
      fw.associate_with_project(@project)

      ps = PrivateSubnet.from_ubid(r.params["private-subnet-id"])
      fw.associate_with_private_subnet(ps) if ps

      flash["notice"] = "'#{r.params["name"]}' is created"

      r.redirect "#{@project.path}#{Firewall[fw.id].path}"
    end
  end
end
