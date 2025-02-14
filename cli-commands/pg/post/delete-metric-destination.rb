# frozen_string_literal: true

UbiCli.on("pg").run_on("delete-metric-destination") do
  options("ubi pg location/(pg-name|_pg-ubid) delete-metric-destination id")

  args 1, invalid_args_message: "metric destination id is required"

  run do |ubid|
    if ubid.include?("/")
      raise Rodish::CommandFailure, "invalid metric destination id format"
    end

    delete(pg_path("/metric-destination/#{ubid}")) do |data|
      ["Metric destination, if it exists, has been scheduled for deletion"]
    end
  end
end
