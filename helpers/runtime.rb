# frozen_string_literal: true

class Clover < Roda
  def get_runtime_jwt_payload
    return unless (v = request.env["HTTP_AUTHORIZATION"])
    jwt_token = v.sub(%r{\ABearer:?\s+}, "")
    begin
      JWT.decode(jwt_token, Config.clover_runtime_token_secret, true, {algorithm: "HS256"})[0]
    rescue JWT::DecodeError
    end
  end
end
