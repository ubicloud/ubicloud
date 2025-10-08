# frozen_string_literal: true

module Ubicloud
  class GithubRepository < Model
    set_prefix "gp"

    set_columns :id, :name

    singleton_class.undef_method(:create)
    singleton_class.undef_method(:list)

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

    undef_method :rename_to
    undef_method :location
    undef_method :destroy

    # The installation name for the repository.
    def installation_name
      @values[:installation_name]
    end

    # Check whether the repository exists. Returns nil if it does not exist.
    def check_exists
      _info(missing: nil)
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

    private

    def load_object_info_from_id(missing: :raise)
      _info(missing:)
    end

    def _path(rest = "")
      "github/#{installation_name}/repository/#{values[:id] || values[:name]}#{rest}"
    end
  end
end
