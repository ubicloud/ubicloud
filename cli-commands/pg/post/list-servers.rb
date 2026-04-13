# frozen_string_literal: true

UbiCli.on("pg").run_on("list-servers") do
  desc "List servers for a PostgreSQL database"

  key = :servers_list

  options("ubi pg (location/pg-name | pg-id) list-servers [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    servers = sdk_object.servers
    response(format_rows(%i[id role state synchronization_status vm], servers, headers: opts[key][:"no-headers"] != false))
  end
end
