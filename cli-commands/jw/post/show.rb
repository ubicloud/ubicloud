# frozen_string_literal: true

UbiCli.on("jw").run_on("show") do
  desc "Show details for a trusted JWT issuer"

  banner "ubi jw jw-id show"

  run do
    jw = @sdk_object
    response([
      "id: ", jw.id, "\n",
      "name: ", jw.name, "\n",
      "issuer: ", jw.issuer, "\n",
      "jwks_uri: ", jw.jwks_uri, "\n",
      "audience: ", jw.audience.to_s,
    ])
  end
end
