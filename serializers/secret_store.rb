# frozen_string_literal: true

class Serializers::SecretStore < Serializers::Base
  def self.serialize_internal(secret_store, options = {})
    h = {
      id: secret_store.ubid,
      name: secret_store.name,
      description: secret_store.description,
    }

    if options[:detailed]
      h[:secrets] = Serializers::Secret.serialize(secret_store.secrets)
    end

    h
  end
end
