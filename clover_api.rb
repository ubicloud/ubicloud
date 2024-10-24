# frozen_string_literal: true

class CloverApi < Roda
  include CloverBase

  plugin :default_headers,
    "Content-Type" => "application/json"

  plugin :hash_branches
  plugin :json
  plugin :json_parser

  NAME_OR_UBID = /([a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?)|_([a-z0-9]{26})/

  autoload_routes("api")

  plugin :not_found do
    response["Content-Type"] = "application/json"
    {
      error: {
        code: 404,
        type: "ResourceNotFound",
        message: "Sorry, we couldn’t find the resource you’re looking for."
      }
    }.to_json
  end

  plugin :error_handler do |e|
    response["Content-Type"] = "application/json"
    error = parse_error(e)

    {error: error}.to_json
  end

  plugin :rodauth do
    enable :argon2, :json, :jwt, :active_sessions, :login

    only_json? true
    use_jwt? true

    # Converting rodauth error response to the common error format of the API
    json_response_body do |hash|
      # In case of an error, rodauth returns the error in the following format
      # {
      #   (required) "error": "There was an error logging in"
      #   (optional) "field-error": [
      #     "password",
      #     "invalid password"
      #   ]
      # }
      if json_response_error?
        error_message = hash["error"]
        type, code = case error_message
        when "There was an error logging in"
          ["InvalidCredentials", 401]
        when "invalid JWT format or claim in Authorization header"
          ["InvalidRequest", 400]
        when "Please login to continue"
          ["LoginRequired", 401]
        else
          # :nocov:
          ["AuthenticationError", 401]
          # :nocov:
        end

        hash.clear
        hash["error"] = {
          "code" => code,
          "type" => type,
          "message" => error_message
        }
      end

      hash.to_json
    end

    hmac_secret Config.clover_session_secret
    jwt_secret Config.clover_session_secret
    argon2_secret { Config.clover_session_secret }
    require_bcrypt? false
  end

  route do |r|
    r.rodauth
    rodauth.check_active_session
    rodauth.require_authentication

    @current_user = Account[rodauth.session_value]

    r.hash_branches("")
  end
end
