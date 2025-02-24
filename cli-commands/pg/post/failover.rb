# frozen_string_literal: true

UbiCli.on("pg").run_on("failover") do
  options("ubi pg location/(pg-name|pg-id) failover")

  run do
    post(pg_path("/failover")) do |data|
      ["Failover initiated for PostgreSQL database with id: #{data["id"]}"]
    end
  end
end
