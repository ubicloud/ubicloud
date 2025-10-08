# frozen_string_literal: true

class Serializers::GithubRepository < Serializers::Base
  def self.serialize_internal(repository, options = {})
    {
      id: repository.ubid,
      installation_name: options[:installation].name,
      name: repository.repository_name
    }
  end
end
