# frozen_string_literal: true

UbiCli.on("pg").run_on("remove-cert-auth-user") do
  desc "Remove user from list of users authenticating with client certificate authentication"

  banner "ubi pg (location/pg-name | pg-id) remove-cert-auth-user name"

  args 1

  run do |name|
    data = sdk_object.remove_cert_auth_user(name)
    body = []
    body << "Users using certificate authentication:\n"
    if data[:items].empty?
      body << "No users using certificate authentication.\n"
    else
      data[:items].each_with_index do |user, i|
        body << "  " << (i + 1).to_s << ": " << user << "\n"
      end
    end
    response(body)
  end
end
