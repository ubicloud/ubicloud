# frozen_string_literal: true

module Ubicloud
  class JwtIssuer < BaseModel
    extend BaseList
    include BaseCheckExists
    include BaseDestroy

    set_prefix "jw"

    set_fragment "token/jwt-issuer"

    set_columns :id, :name, :issuer, :jwks_uri, :audience

    # Create a new JWT issuer with the given parameters.
    def self.create(adapter, name:, issuer:, jwks_uri:, audience: nil)
      body = {name:, issuer:, jwks_uri:}
      body[:audience] = audience if audience
      new(adapter, adapter.post(fragment.to_s, **body))
    end

    # Create a new JwtIssuer instance. +values+ can be:
    #
    # * a string in a valid id format for the model
    # * a hash with symbol keys (must contain :id key)
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        raise Error, "invalid #{self.class.fragment} id" unless self.class.id_regexp.match?(values)

        @values = {id: values}
      when Hash
        raise Error, "hash must have :id key" unless values[:id]

        @values = {}
        merge_into_values(values)
      else
        raise Error, "unsupported value initializing #{self.class}: #{values.inspect}"
      end
    end

    private

    def _path
      "#{self.class.fragment}/#{id}"
    end
  end
end
