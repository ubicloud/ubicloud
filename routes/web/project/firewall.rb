# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "firewall") do |r|
    @serializer = Serializers::Web::Firewall

    r.get true do
      authorized_firewalls = @project.firewalls_dataset.authorized(@current_user.id, "Firewall:view").all
      @firewalls = serialize(authorized_firewalls)

      view "firewall/index"
    end

  end
end
