# frozen_string_literal: true

module Ubicloud
  class VmInitScript < Model
    set_prefix "1n"

    set_fragment "vm-init-script"

    set_columns :id, :name, :script

    # Create a new VM init script with the given parameters.
    def self.create(adapter, name:, script:)
      new(adapter, adapter.post(fragment.to_s, name:, script:))
    end

    # Do not support a specific location when getting a list of VM init scripts.
    def self.list(adapter)
      super
    end

    # Create a new VmInitScript instance. +values+ can be:
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
          raise Error, "invalid VM Init Script id format"
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

    # The VM init script's id, which will be a 26 character string.
    def id
      if (id = @values[:id])
        id
      else
        info
        @values[:id]
      end
    end

    # The VM init script's name.
    def name
      if (name = @values[:name])
        name
      else
        info
        @values[:name]
      end
    end

    # Check whether the VM init script exists. Returns nil if it does not exist.
    def check_exists
      _info(missing: nil)
    end

    # Update the name of the VM init script.
    def rename_to(name)
      merge_into_values(adapter.post(_path, name:))
    end

    # Update the script for the instance.
    def update_script(script)
      merge_into_values(adapter.post(_path, script:))
    end

    private

    # The path to use for VM init scripts, which doesn't include the location
    # and does not support additional arguments.
    def _path
      "#{self.class.fragment}/#{@values[:id] || @values[:name]}"
    end
  end
end
