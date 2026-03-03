# frozen_string_literal: true

UbiCli.on("pg").run_on("create-client-cert-keypair") do
  desc "Create client certificate keypair with given common name, expiring after a duration of seconds"

  banner "ubi pg (location/pg-name | pg-id) create-client-cert-keypair common-name duration"

  args 2

  run do |common_name, duration|
    response(sdk_object.create_client_cert_keypair(common_name:, duration: duration.to_i))
  end
end
