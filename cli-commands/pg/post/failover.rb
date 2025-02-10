# frozen_string_literal: true

UbiRodish.on("pg").run_is("failover") do
  post(project_path("location/#{@location}/postgres/#{@name}/failover")) do |data|
    ["Failover initiated for PostgreSQL database with id: #{data["id"]}"]
  end
end
