# frozen_string_literal: true

UbiCli.on("pg").run_on("reset-superuser-password") do
  options("ubi pg location/(pg-name|_pg-id) reset-superuser-password new-password")

  args 1, invalid_args_message: "password is required"

  run do |password|
    post(pg_path("/reset-superuser-password"), "password" => password) do |data|
      ["Superuser password reset scheduled for PostgreSQL database with id: #{data["id"]}"]
    end
  end
end
