# frozen_string_literal: true

UbiRodish.on("pg").run_on("failover") do
  options("ubi pg location-name/(pg-name|_pg-ubid) failover")

  run do
    post(project_path("location/#{@location}/postgres/#{@name}/failover")) do |data|
      ["Failover initiated for PostgreSQL database with id: #{data["id"]}"]
    end
  end
end
