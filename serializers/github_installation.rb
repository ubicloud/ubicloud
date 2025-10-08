# frozen_string_literal: true

class Serializers::GithubInstallation < Serializers::Base
  def self.serialize_internal(installation, options = {})
    {
      id: installation.ubid,
      name: installation.name
    }
  end
end
