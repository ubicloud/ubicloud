# frozen_string_literal: true

module Ubicloud
  class SecretStore < BaseModel
    extend BaseList
    include BaseCheckExists
    include BaseLazyId
    include BaseDestroy

    set_prefix "ss"

    set_fragment "secret-store"

    set_columns :id, :name, :description

    # Create a new secret store with the given parameters.
    def self.create(adapter, name:, description: nil)
      params = {name:}
      params[:description] = description if description
      new(adapter, adapter.post(fragment.to_s, **params))
    end

    # Create a new SecretStore instance. +values+ can be:
    #
    # * a string in a valid id format for the model
    # * a string with the secret store name
    # * a hash with symbol keys (must contain :id or :name key)
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        @values = if self.class.id_regexp.match?(values)
          {id: values}
        elsif values.include?("/")
          raise Error, "invalid secret store id format"
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

    # Rename the secret store to the given name.
    def rename_to(name)
      merge_into_values(adapter.post(_path, name:))
    end

    # Update the secret store description.
    def update_description(description)
      merge_into_values(adapter.post(_path, description:))
    end

    # Return an array of the keys stored in the secret store.
    def list_secrets
      adapter.get(_path("/secret"))[:items].map { it[:key] }
    end

    # Return the decrypted value for the given key.
    def get_secret(key)
      check_no_slash(key, "invalid secret key format")
      adapter.get(_path("/secret/#{key}"))[:value]
    end

    # Set the value for the given key, creating or updating it. Returns the value.
    def set_secret(key, value)
      adapter.post(_path("/secret"), key:, value:)[:value]
    end

    # Delete the secret with the given key. Returns nil.
    def delete_secret(key)
      check_no_slash(key, "invalid secret key format")
      adapter.delete(_path("/secret/#{key}"))
      nil
    end

    private

    # The path to use for secret stores, which doesn't include the location
    # and does not support additional arguments.
    def _path(rest = "")
      "#{self.class.fragment}/#{@values[:id] || @values[:name]}#{rest}"
    end
  end
end
