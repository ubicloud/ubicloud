# frozen_string_literal: true

class Serializers::GithubInstallation < Serializers::Base
  def self.serialize_internal(ins, options = {})
    {
      id: ins.id,
      ubid: ins.ubid,
      name: ins.name,
      type: ins.type,
      cache_enabled: ins.cache_enabled,
      installation_id: ins.installation_id,
      installation_url: "https://github.com/apps/#{Config.github_app_name}/installations/#{ins.installation_id}"
    }
  end
end
