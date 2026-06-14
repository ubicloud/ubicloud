# frozen_string_literal: true

class Serializers::PostgresManagedRole < Serializers::Base
  def self.serialize_internal(role, options = {})
    {
      id: role.ubid,
      name: role.name,
      auth_type: role.auth_type,
      state: role.state,
      certificate_expires_at: role.cert_not_after&.iso8601,
      has_certificate: !role.cert.nil?,
    }
  end
end
