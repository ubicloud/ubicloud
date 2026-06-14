# frozen_string_literal: true

class Serializers::Secret < Serializers::Base
  def self.serialize_internal(secret, options = {})
    h = {
      key: secret.key,
    }

    # Values are only included when explicitly requested (single-secret reads
    # and writes), so bulk listings stay lightweight.
    h[:value] = secret.value if options[:detailed]

    h
  end
end
