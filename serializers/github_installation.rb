# frozen_string_literal: true

class Serializers::GithubInstallation < Serializers::Base
  def self.serialize_internal(ins, options = {})
    {
      id: ins.id,
      name: ins.name,
      type: ins.type,
      installation_id: ins.installation_id,
      installation_url: ins.installation_url
    }
  end
end
