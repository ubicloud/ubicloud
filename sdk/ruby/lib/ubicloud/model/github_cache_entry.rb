# frozen_string_literal: true

module Ubicloud
  class GithubCacheEntry < BaseModel
    include BaseCheckExists
    include BaseDestroy

    set_prefix "ge"

    set_columns :key, :scope, :size, :created_at, :last_accessed_at
    set_direct_columns :installation_name, :repository_name

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

    private

    def _path
      "github/#{installation_name}/repository/#{repository_name}/cache/#{id}"
    end
  end
end
