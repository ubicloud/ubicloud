# frozen_string_literal: true

module Ubicloud
  class InitScriptTag < Model
    set_prefix "it"

    set_fragment "init-script-tag"

    set_columns :id, :name, :version, :size, :created_at

    # Push a new init script to the registry. Auto-increments version.
    def self.create(adapter, name:, content:)
      new(adapter, adapter.post(fragment.to_s, name:, content:))
    end

    # List all init script tags in the project.
    def self.list(adapter)
      adapter.get(fragment.to_s)[:items].map { new(adapter, it) }
    end

    # Create a new InitScriptTag instance.
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        @values = if self.class.id_regexp.match?(values)
          {id: values}
        else
          {ref: values}
        end
      when Hash
        @values = {}
        merge_into_values(values)
      else
        raise Error, "unsupported value initializing #{self.class}: #{values.inspect}"
      end
    end

    undef_method :location
    undef_method :load_object_info_from_id

    # The init script tag's id.
    def id
      if (id = @values[:id])
        id
      else
        info
        @values[:id]
      end
    end

    # Check whether the init script tag exists.
    def check_exists
      _info(missing: nil)
    end

    private

    def _path(rest = "")
      ref = @values[:id] || @values[:ref]
      "#{self.class.fragment}/#{ref}#{rest}"
    end
  end
end
