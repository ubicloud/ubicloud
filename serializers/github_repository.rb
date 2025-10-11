# frozen_string_literal: true

class Serializers::GithubRepository < Serializers::Base
  def self.serialize_internal(repository, options = {})
    h = {
      id: repository.ubid,
      installation_name: options[:installation].name,
      name: repository.repository_name
    }

    if options[:detailed]
      h[:cache_entries] = Serializers::GithubCacheEntry.serialize(repository.cache_entries, installation: options[:installation], repository:)
    end

    h
  end
end
