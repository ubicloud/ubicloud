# frozen_string_literal: true

module Ubicloud
  class GithubInstallation < Model
    set_prefix "g1"

    set_columns :id, :name, :key, :size

    singleton_class.undef_method(:create)

    # Do not support a specific location when getting a list of GithubInstallations
    def self.list(adapter)
      adapter.get("github")[:items].map { new(adapter, it) }
    end

    # Create a new GithubInstallation instance. +values+ can be:
    #
    # * a string (treated as an id if in valid GithubInstallation id format,
    #   or as a name otherwise)
    # * a hash with symbol keys (must contain :id or :name key)
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        @values = if self.class.id_regexp.match?(values)
          {id: values}
        else
          check_no_slash(values, "invalid GithubInstallation name format")
          {name: values}
        end
      when Hash
        unless values[:id] || values[:name]
          raise Error, "hash must have :id or :name key"
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

    def repositories(reload: false)
      if (repositories = @values[:repositories]) && !reload
        return repositories
      end

      @values[:repositories] = adapter.get(_path("/repository"))[:items].map { GithubRepository.new(adapter, it) }
    end

    # Check whether the cache entry exists. Returns nil if it does not exist.
    def check_exists
      _info(missing: nil)
    end

    private

    def load_object_info_from_id(missing: :raise)
      _info(missing:)
    end

    def _path(rest = "")
      "github/#{values[:id] || values[:name]}#{rest}"
    end
  end
end
