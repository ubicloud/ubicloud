# frozen_string_literal: true

UbiCli.on("pg").run_on("list-backups") do
  desc "List backups for a PostgreSQL database"

  key = :backups_list

  options("ubi pg (location/pg-name | pg-id) list-backups [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    backups = sdk_object.backups
    response(format_rows(%i[key last_modified], backups, headers: opts[key][:"no-headers"] != false))
  end
end
