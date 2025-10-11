# frozen_string_literal: true

class Serializers::GithubInstallation < Serializers::Base
  def self.serialize_internal(installation, options = {})
    h = {
      id: installation.ubid,
      name: installation.name
    }

    if options[:detailed]
      h[:repositories] = Serializers::GithubRepository.serialize(installation.repositories, installation:)
    end

    h
  end
end
