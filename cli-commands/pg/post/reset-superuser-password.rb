# frozen_string_literal: true

UbiRodish.on("pg").run_on("reset-superuser-password") do
  options("ubi pg location-name/(pg-name|_pg-ubid) reset-superuser-password new-password")

  args 1, invalid_args_message: "password is required"

  run do |password|
    post(project_path("location/#{@location}/postgres/#{@name}/reset-superuser-password"), "password" => password) do |data|
      ["Superuser password reset scheduled for PostgreSQL database with id: #{data["id"]}"]
    end
  end
end
