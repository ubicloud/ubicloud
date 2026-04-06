# frozen_string_literal: true

module Ubicloud
  class GithubRepository < BaseModel
    include BaseCheckExists
    include BaseLazyId

    set_prefix "gp"

    set_columns :id, :name
    set_direct_columns :installation_name

    # Create a new GithubRepository instance. +values+ must be a hash with
    # :installation_name key and either :id or :name keys.
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when Hash
        id_or_name = values[:id] || values[:name]
        unless values[:installation_name] && id_or_name
          raise Error, "hash must have :installation_name key and either :id or :name keys"
        end
        @values = {}
        merge_into_values(values)
      else
        raise Error, "unsupported value initializing #{self.class}: #{values.inspect}"
      end
    end

    def cache_entries(reload: false)
      if (cache_entries = @values[:cache_entries]) && !reload
        return cache_entries
      end

      @values[:cache_entries] = adapter.get(_path("/cache"))[:items].map { GithubCacheEntry.new(adapter, it) }
    end

    # Remove the cache entry with the given id.
    def remove_cache_entry(id)
      GithubCacheEntry.new(adapter, id:, installation_name:, repository_name: name).destroy
    end

    # Remove all cache entries for the repository.
    def remove_all_cache_entries
      adapter.delete(_path("/cache"))
    end

    private

    def _path(rest = "")
      "github/#{installation_name}/repository/#{values[:id] || values[:name]}#{rest}"
    end
  end
end
