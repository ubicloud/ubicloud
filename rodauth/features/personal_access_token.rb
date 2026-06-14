# frozen-string-literal: true

require "rodauth"

module Rodauth
  Feature.define(:personal_access_token, :PersonalAccessToken) do
    auth_value_method :pat_authorization_remove, /\ABearer:?\s+pat-/i
    session_key :session_pat_key, :pat_id
    session_key :session_managed_identity_key, :managed_identity_id
    session_key :session_managed_identity_project_key, :managed_identity_project_id

    def session
      return @session if defined?(@session)

      @session = s = {}

      token = request.env["HTTP_AUTHORIZATION"].to_s.sub(pat_authorization_remove, "")
      token_id, key = token.split("-", 2)

      return s unless key
      return s unless (uuid = UBID.to_uuid(token_id))
      return s unless (api_key = ApiKey[id: uuid, is_valid: true, used_for: "api"])
      return s unless timing_safe_eql?(api_key.key, key)

      case api_key.owner_table
      when "accounts"
        # Personal access token: the owning account is the authenticated
        # subject, and the token may further restrict its permissions.
        set_session_value(session_key, api_key.owner_id)
        set_session_value(session_pat_key, uuid)
      when "vm"
        # Managed identity: the VM itself is the authenticated subject.
        # There is no account behind the request.
        set_session_value(session_managed_identity_key, api_key.owner_id)
        set_session_value(session_managed_identity_project_key, api_key.project_id)
      end

      s
    end

    # A managed identity request is authenticated even though it has no
    # account session value.
    def logged_in?
      super || !session[session_managed_identity_key].nil?
    end
  end
end
