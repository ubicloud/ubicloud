# frozen_string_literal: true

class Serializers::TrustedJwtIssuer < Serializers::Base
  def self.serialize_internal(issuer, options = {})
    {
      id: issuer.ubid,
      name: issuer.name,
      issuer: issuer.issuer,
      jwks_uri: issuer.jwks_uri,
      audience: issuer.audience,
    }
  end
end
