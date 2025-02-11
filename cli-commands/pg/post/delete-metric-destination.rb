# frozen_string_literal: true

UbiRodish.on("pg").run_is("delete-metric-destination", args: 1, invalid_args_message: "metric destination id is required") do |ubid|
  if ubid.include?("/")
    raise Rodish::CommandFailure, "invalid metric destination id format"
  end

  delete(project_path("location/#{@location}/postgres/#{@name}/metric-destination/#{ubid}")) do |data|
    ["Metric destination, if it exists, has been scheduled for deletion"]
  end
end
