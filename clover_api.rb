# frozen_string_literal: true

class CloverApi < Roda
  include CloverBase

  plugin :default_headers,
    "Content-Type" => "application/json"

  plugin :hash_branches
  plugin :json
  plugin :json_parser

  autoload_routes("api")

  plugin :not_found do
    {
      error: {
        code: 404,
        title: "Resource not found",
        message: "Sorry, we couldn’t find the resource you’re looking for."
      }
    }.to_json
  end

  plugin :error_handler do |e|
    error = parse_error(e)

    {error: error}.to_json
  end

  plugin :rodauth do
    enable :argon2, :json, :jwt, :active_sessions, :login

    only_json? true
    use_jwt? true

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
