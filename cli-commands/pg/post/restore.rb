# frozen_string_literal: true

UbiRodish.on("pg").run_is("restore", args: 2, invalid_args_message: "name and restore target are required") do |name, restore_target|
  params = {
    "name" => name,
    "restore_target" => restore_target
  }
  post(project_path("location/#{@location}/postgres/#{@name}/restore"), params) do |data|
    ["Restored PostgreSQL database scheduled for creation with id: #{data["id"]}"]
  end
end
