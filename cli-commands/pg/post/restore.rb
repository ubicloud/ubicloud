# frozen_string_literal: true

UbiRodish.on("pg").run_on("restore") do
  options("ubi pg location/(pg-name|_pg-ubid) restore new-db-name restore-time")

  args 2, invalid_args_message: "name and restore target are required"

  run do |name, restore_target|
    params = {
      "name" => name,
      "restore_target" => restore_target
    }
    post(pg_path("/restore"), params) do |data|
      ["Restored PostgreSQL database scheduled for creation with id: #{data["id"]}"]
    end
  end
end
