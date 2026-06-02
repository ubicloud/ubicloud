# frozen_string_literal: true

UbiCli.on("jw", "create") do
  desc "Create a JWT issuer"

  options("ubi jw create [options] name issuer jwks-uri", key: :jw_create) do
    on("-a", "--audience=aud", "required aud claim value")
  end

  args 3

  run do |name, issuer, jwks_uri, opts|
    params = underscore_keys(opts[:jw_create])
    id = sdk.jwt_issuer.create(name:, issuer:, jwks_uri:, audience: params[:audience]).id
    response("JWT issuer created with id: #{id}")
  end
end
