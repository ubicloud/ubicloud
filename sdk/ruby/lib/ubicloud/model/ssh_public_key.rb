# frozen_string_literal: true

module Ubicloud
  class SshPublicKey < Model
    set_prefix "sk"

    set_fragment "ssh-public-key"

    set_columns :id, :name, :public_key

    # Create a new SSH public key with the given parameters.
    def self.create(adapter, name:, public_key:)
      new(adapter, adapter.post(fragment.to_s, name:, public_key:))
    end

    # Do not support a specific location when getting a list of SSH public keys.
    def self.list(adapter)
      super
    end

    # Create a new SSHPublicKey instance. +values+ can be:
    #
    # * a string in a valid id format for the model
    # * a hash with symbol keys (must contain :id key)
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        @values = if self.class.id_regexp.match?(values)
          {id: values}
        elsif values.include?("/")
          raise Error, "invalid SSH public key id format"
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

    undef_method :location
    undef_method :load_object_info_from_id

    # The SSH public key's id, which will be a 26 character string.
    def id
      if (id = @values[:id])
        id
      else
        info
        @values[:id]
      end
    end

    # The SSH public key's name.
    def name
      if (name = @values[:name])
        name
      else
        info
        @values[:name]
      end
    end

    # Check whether the SSH public key exists. Returns nil if it does not exist.
    def check_exists
      _info(missing: nil)
    end

    # Update the name of the SSH public key.
    def rename_to(name)
      merge_into_values(adapter.post(_path, name:))
    end

    # Update the public key for the instance.
    def update_public_key(public_key)
      merge_into_values(adapter.post(_path, public_key:))
    end

    private

    # The path to use for SSH public keys, which doesn't include the location
    # and does not support additional arguments.
    def _path
      "#{self.class.fragment}/#{@values[:id] || @values[:name]}"
    end
  end
end
