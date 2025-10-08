# frozen_string_literal: true

module Ubicloud
  class GithubCacheEntry < Model
    set_prefix "ge"

    set_columns :key, :size

    singleton_class.undef_method(:create)
    singleton_class.undef_method(:list)

    # Create a new GithubCacheEntry instance. +values+ must be a hash with
    # :id, :repository_name, and :installation_name keys.
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when Hash
        unless values[:id] && values[:repository_name] && values[:installation_name]
          raise Error, "hash must have :id, :repository_name, and :installation_name keys"
        end
        @values = {}
        merge_into_values(values)
      else
        raise Error, "unsupported value initializing #{self.class}: #{values.inspect}"
      end
    end

    undef_method :rename_to
    undef_method :name
    undef_method :location

    # The cache entry's id, which will be a 26 character string.
    def id
      @values[:id]
    end

    # The installation name for the cache entry.
    def installation_name
      @values[:installation_name]
    end

    # The repository name for the cache entry.
    def repository_name
      @values[:repository_name]
    end

    # Check whether the cache entry exists. Returns nil if it does not exist.
    def check_exists
      _info(missing: nil)
    end

    # Remove the cache entry.
    def destroy
      adapter.delete(_path)
    end

    private

    def _path
      "github/#{installation_name}/repository/#{repository_name}/cache/#{id}"
    end
  end
end
