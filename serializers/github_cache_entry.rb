# frozen_string_literal: true

class Serializers::GithubCacheEntry < Serializers::Base
  def self.serialize_internal(cache_entry, options = {})
    {
      id: cache_entry.ubid,
      installation_name: options[:installation].name,
      repository_name: options[:repository].name,
      key: cache_entry.key,
      scope: cache_entry.scope,
      size: cache_entry.size,
      created_at: cache_entry.created_at.utc.iso8601,
      last_accessed_at: cache_entry.last_accessed_at&.utc&.iso8601,
    }
  end
end
