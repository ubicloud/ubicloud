# frozen_string_literal: true

UbiRodish.on("pg").run_is("reset-superuser-password", args: 1, invalid_args_message: "password is required") do |password|
  post(project_path("location/#{@location}/postgres/#{@name}/reset-superuser-password"), "password" => password) do |data|
    ["Superuser password reset scheduled for PostgreSQL database with id: #{data["id"]}"]
  end
end
