# frozen_string_literal: true

module Ubicloud
  # A PostgreSQL database in its own micro-VM.
  #
  # Embers are not location-scoped in their URL the way most resources are:
  # an ember is meant to be obtained without thinking about where it lives, so
  # the location is a create-time parameter rather than part of its identity.
  class PostgresEmber < BaseModel
    extend BaseList
    include BaseCheckExists
    include BaseLazyId
    include BaseDestroy

    set_prefix "cc"

    set_fragment "postgres-ember"

    set_columns :id, :name, :location, :state, :pg_version, :database, :memory_mib,
      :idle_timeout_seconds, :created_at, :last_activity_at, :expires_at,
      :host, :port, :user, :password, :connection_string

    # Create a new ember. Every parameter has a default, because obtaining one
    # without deciding anything is the point. Reached through Postgres, which
    # is the product an ember is one shape of.
    def self.create(adapter, name: nil, location: nil, pg_version: nil, database: nil)
      params = {name:, location:, pg_version:, database:}
      params.compact!
      new(adapter, adapter.post(fragment.to_s, **params))
    end

    # Move an anonymous ember into this project. The token is single use.
    def self.claim(adapter, claim_token)
      new(adapter, adapter.post("#{fragment}/claim", claim_token:))
    end

    # Create a new Ember instance. +values+ can be:
    #
    # * a string in a valid id format for the model
    # * a string naming the ember
    # * a hash with symbol keys (must contain :id or :name key)
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        @values = if self.class.id_regexp.match?(values)
          {id: values}
        elsif values.include?("/")
          raise Error, "invalid PostgreSQL ember id format"
        else
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

    # Stop the ember. Its storage survives and it costs nothing until the
    # next connection, which brings it back.
    def pause
      merge_into_values(adapter.post("#{_path}/pause"))
      self
    end

    # Bring a paused ember back. Connecting to it does this too.
    def resume
      merge_into_values(adapter.post("#{_path}/resume"))
      self
    end

    # Give the ember a new superuser password and return it in the values.
    def reset_password
      merge_into_values(adapter.post("#{_path}/reset-password"))
      self
    end

    private

    # Embers are addressed by id or name alone, with no location in the
    # path.
    def _path(rest = "")
      "#{self.class.fragment}/#{@values[:id] || @values[:name]}#{rest}"
    end
  end
end
