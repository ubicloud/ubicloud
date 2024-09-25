# frozen_string_literal: true

class Serializers::ProjectInvitation < Serializers::Base
  def self.serialize_internal(pi, options = {})
    {
      email: pi.email,
      expires_at: pi.expires_at.strftime("%B %d, %Y"),
      policy: pi.policy
    }
  end
end
