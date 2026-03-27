# frozen-string-literal: true

require "rodauth"

module Rodauth
  Feature.define(:jwt_scope_token, :JwtScopeToken) do
    session_key :session_jwt_key, :jwt_id
    session_key :session_jwt_payload_key, :jwt_payload

    def session
      return super if defined?(@session)

      raw = request.env["HTTP_AUTHORIZATION"].to_s

      # Defer to PAT auth for pat- prefixed tokens or missing header
      return super if raw.empty? || raw.match?(/\ABearer:?\s+pat-/i)

      token = raw.sub(/\ABearer:?\s+/i, "")

      payload = JWT.decode(token, nil, false)[0]
      return super unless payload.is_a?(Hash) && (iss = payload["iss"])
      return super unless (project_ubid = request.path_info[%r{\A/project/(pj[a-z0-9]{24})}i, 1])
      return super unless (project_id = UBID.to_uuid(project_ubid))
      return super unless (issuer_config = TrustedJwtIssuer.first(project_id:, issuer: iss))

      payload = issuer_config.decode_jwt(token)

      @session = s = {}
      set_session_value(session_key, issuer_config.account_id)
      set_session_value(session_jwt_key, issuer_config.id)
      set_session_value(session_jwt_payload_key, payload)

      s
    rescue JWT::DecodeError
      super
    end
  end
end
