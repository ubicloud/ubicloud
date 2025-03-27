# frozen-string-literal: true

require "rodauth"

module Rodauth
  Feature.define(:personal_access_token, :PersonalAccessToken) do
    auth_value_method :pat_authorization_remove, /\ABearer:?\s+pat-/
    session_key :session_pat_key, :pat_id

    def session
      return @session if defined?(@session)

      @session = s = {}

      token = request.env["HTTP_AUTHORIZATION"].to_s.sub(pat_authorization_remove, "")
      token_id, key = token.split("-", 2)

      return s unless (uuid = UBID.to_uuid(token_id))
      return s unless (api_key = ApiKey[owner_table: "accounts", id: uuid, is_valid: true])
      return s unless timing_safe_eql?(api_key.key, key)

      set_session_value(session_key, api_key.owner_id)
      set_session_value(session_pat_key, uuid)

      s
    end
  end
end
