# frozen_string_literal: true

class Serializers::GithubCacheEntry < Serializers::Base
  def self.serialize_internal(cache_entry, options = {})
    {
      id: cache_entry.ubid,
      installation_name: options[:installation].name,
      repository_name: options[:repository].name,
      key: cache_entry.key,
      size: cache_entry.size
    }
  end
end
