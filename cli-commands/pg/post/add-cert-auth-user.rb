# frozen_string_literal: true

UbiCli.on("pg").run_on("add-cert-auth-user") do
  desc "Add user to list of users authenticating with client certificate authentication"

  banner "ubi pg (location/pg-name | pg-id) add-cert-auth-user name"

  args 1

  run do |name|
    data = sdk_object.add_cert_auth_user(name)
    body = []
    body << "Users using certificate authentication:\n"
    data[:items].each_with_index do |user, i|
      body << "  " << (i + 1).to_s << ": " << user << "\n"
    end
    response(body)
  end
end
