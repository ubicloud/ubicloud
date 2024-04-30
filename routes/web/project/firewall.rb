# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "firewall") do |r|
    @serializer = Serializers::Web::Firewall

    r.get true do
      @firewalls = serialize(@project.firewalls_dataset.authorized(@current_user.id, "Firewall:view").all)

      view "firewall/index"
    end

  end
end
