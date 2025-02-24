# frozen_string_literal: true

UbiCli.on("pg").run_on("restart") do
  options("ubi pg location/(pg-name|pg-id) restart")

  run do
    post(pg_path("/restart")) do |data|
      ["Scheduled restart of PostgreSQL database with id #{data["id"]}"]
    end
  end
end
