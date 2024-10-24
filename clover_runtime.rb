# frozen_string_literal: true

require "jwt"
require "roda"

class CloverRuntime < Roda
  include CloverBase

  plugin :default_headers, "Content-Type" => "application/json"

  plugin :hash_branches
  plugin :json
  plugin :all_verbs
  plugin :json_parser

  autoload_routes("runtime")

  plugin :error_handler do |e|
    error = parse_error(e)

    {error: error}.to_json unless error[:code] == 204
  end

  def get_jwt_payload(request)
    return unless (v = request.env["HTTP_AUTHORIZATION"])
    jwt_token = v.sub(%r{\ABearer:?\s+}, "")
    begin
      JWT.decode(jwt_token, Config.clover_runtime_token_secret, true, {algorithm: "HS256"})[0]
    rescue JWT::DecodeError
    end
  end

  route do |r|
    if (jwt_payload = get_jwt_payload(r)).nil? || (@vm = Vm.from_ubid(jwt_payload["sub"])).nil?
      fail CloverError.new(400, "InvalidRequest", "invalid JWT format or claim in Authorization header")
    end

    r.hash_branches("")
  end
end
