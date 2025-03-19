# frozen_string_literal: true

UbiCli.on("pg").run_on("reset-superuser-password") do
  desc "Reset the superuser password for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) reset-superuser-password new-password"

  args 1

  run do |password|
    id = sdk_object.reset_superuser_password(password).id
    response("Superuser password reset scheduled for PostgreSQL database with id: #{id}")
  end
end
