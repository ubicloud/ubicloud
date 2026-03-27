# frozen_string_literal: true

UbiCli.on("jw", "create") do
  desc "Create a trusted JWT issuer"

  options("ubi jw create [options]", key: :jw_create) do
    on("-n", "--name=name", "name for the issuer")
    on("-i", "--issuer=iss", "issuer (iss claim value)")
    on("-j", "--jwks-uri=uri", "JWKS endpoint URI")
    on("-a", "--audience=aud", "required aud claim value")
  end

  run do |opts|
    params = underscore_keys(opts[:jw_create])
    id = sdk.trusted_jwt_issuer.create(
      name: params[:name],
      issuer: params[:issuer],
      jwks_uri: params[:jwks_uri],
      audience: params[:audience],
    ).id
    response("Trusted JWT issuer created with id: #{id}")
  end
end
