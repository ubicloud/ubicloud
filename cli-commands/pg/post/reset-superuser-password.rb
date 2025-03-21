# frozen_string_literal: true

UbiCli.on("pg").run_on("reset-superuser-password") do
  desc "Reset the superuser password for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) reset-superuser-password new-password"

  args 1

  run do |password|
    post(pg_path("/reset-superuser-password"), "password" => password) do |data|
      ["Superuser password reset scheduled for PostgreSQL database with id: #{data["id"]}"]
    end
  end
end
