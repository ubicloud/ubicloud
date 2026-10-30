# frozen_string_literal: true

module Ubicloud
  class GithubInstallation < BaseModel
    extend BaseList
    include BaseCheckExists
    include BaseLazyId

    set_prefix "g1"

    set_fragment "github"

    set_columns :id, :name, :key, :size

    # Return the URL that installs the GitHub App. After installing, GitHub
    # shows a code to pass to create.
    def self.connect_url(adapter)
      adapter.post("#{fragment}/connect")[:url]
    end

    # Connect a GitHub installation to the project, using the code shown
    # after installing the GitHub App from connect_url.
    def self.create(adapter, code:)
      new(adapter, adapter.post(fragment.to_s, code:))
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

    def repositories(reload: false)
      if (repositories = @values[:repositories]) && !reload
        return repositories
      end

      @values[:repositories] = adapter.get(_path("/repository"))[:items].map { GithubRepository.new(adapter, it) }
    end

    private

    def _path(rest = "")
      "#{self.class.fragment}/#{values[:id] || values[:name]}#{rest}"
    end
  end
end
