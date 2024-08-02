# frozen_string_literal: true

require "committee"
require "roda"
require_relative "db"

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

  plugin :rodauth, json: :only do
    enable :argon2, :json, :jwt, :active_sessions, :login
    use_json? true
    only_json? true
    use_jwt? true

    # Converting rodauth error response to the common error format of the API
    json_response_body do |hash|
      p [5, hash]
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

  OPENAPI = OpenAPIParser.load("openapi.yml", strict_reference_validation: true)
  SCHEMA = Committee::Drivers::OpenAPI3::Driver.new.parse(OPENAPI)

  class CustomErrorHandler
    def call(error, request)
      printed_error = error.respond_to?(:original_error) ? error.original_error : error
      puts "Schema validation failed: #{printed_error.inspect}"
      puts "Request: #{request.inspect}"
      puts "Error details: #{error.inspect}"
      # raise error
    end
  end

  use Committee::Middleware::ResponseValidation, schema: SCHEMA, strict: true, prefix: "/api", error_handler: CustomErrorHandler.new

  route do |r|
    r.rodauth
    rodauth.check_active_session
    rodauth.require_authentication

    @current_user = Account[rodauth.session_value]

    Committee::Middleware::RequestValidation.new(app, schema: SCHEMA, strict: true, prefix: "/api", error_handler: CustomErrorHandler.new).call(r.env)

    r.hash_branches("")
  end
end
