# frozen_string_literal: true

require "committee"

class CloverApi < Roda
  include CloverBase

  plugin :default_headers,
    "Content-Type" => "application/json"

  plugin :hash_branches
  plugin :json
  plugin :json_parser

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

  OPENAPI = OpenAPIParser.load("openapi.yml", strict_reference_validation: true) unless const_defined?(:OPENAPI)
  SCHEMA = Committee::Drivers::OpenAPI3::Driver.new.parse(OPENAPI) unless const_defined?(:SCHEMA)
  SCHEMA_ROUTER = SCHEMA.build_router(schema: SCHEMA, strict: true, prefix: "/api") unless const_defined?(:SCHEMA_ROUTER)

  use Committee::Middleware::ResponseValidation, schema: SCHEMA, strict: true, prefix: "/api"

  route do |r|
    r.rodauth
    rodauth.check_active_session
    rodauth.require_authentication

    begin
      schema_validator = SCHEMA_ROUTER.build_schema_validator(request)
      schema_validator.request_validate(Rack::Request.new(r.env))

      # FIXME: strict validation
      # raise Committee::NotFound, "That request method and path combination isn't defined." if !schema_validator.link_exist?
    rescue JSON::ParserError => e
      raise Committee::InvalidRequest.new("Request body wasn't valid JSON.", original_error: e)
    end

    @current_user = Account[rodauth.session_value]

    r.hash_branches("")
  end
end
