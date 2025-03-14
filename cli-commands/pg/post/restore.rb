# frozen_string_literal: true

UbiCli.on("pg").run_on("restore") do
  desc "Restore a PostgreSQL database backup to a new database"

  banner "ubi pg (location/pg-name | pg-id) restore new-db-name restore-time"

  args 2

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
