# frozen-string-literal: true

module Rodauth
  Feature.define(:personal_access_token, :PersonalAccessToken) do
    depends :jwt

    auth_value_method :pat_authorization_remove, /\ABearer:?\s+pat-/
    session_key :session_pat_key, :pat_id

    def use_pat?
      pat_authorization_remove.match?(request.env["HTTP_AUTHORIZATION"].to_s)
    end

    # We override use_jwt? in the rodauth configuration, so this is not used.
    # def use_jwt?
    #   super && !use_pat?
    # end

    def session
      return @session if defined?(@session)
      return super unless use_pat?

      @session = s = {}

      token = request.env["HTTP_AUTHORIZATION"].sub(pat_authorization_remove, "")
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
