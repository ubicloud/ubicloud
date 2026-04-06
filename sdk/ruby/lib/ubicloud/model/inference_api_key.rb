# frozen_string_literal: true

module Ubicloud
  class InferenceApiKey < BaseModel
    extend BaseList
    include BaseCheckExists
    include BaseDestroy

    set_prefix "ak"

    set_fragment "inference-api-key"

    set_columns :id, :key

    # Create a new inference api key
    def self.create(adapter)
      new(adapter, adapter.post(fragment.to_s))
    end

    # Create a new InferenceApiKey instance. +values+ can be:
    #
    # * a string in a valid id format for the model
    # * a hash with symbol keys (must contain :id key)
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        unless self.class.id_regexp.match?(values)
          raise Error, "invalid #{self.class.fragment} id"
        end

        @values = {id: values}
      when Hash
        unless values[:id]
          raise Error, "hash must have :id key"
        end

        @values = {}
        merge_into_values(values)
      else
        raise Error, "unsupported value initializing #{self.class}: #{values.inspect}"
      end
    end

    private

    # The path to use for inference api keys, which doesn't include the location
    # and does not support additional arguments.
    def _path
      "#{self.class.fragment}/#{id}"
    end
  end
end
