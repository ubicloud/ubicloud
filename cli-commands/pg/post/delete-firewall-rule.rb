# frozen_string_literal: true

UbiRodish.on("pg").run_on("delete-firewall-rule") do
  options("ubi pg location-name/(pg-name|_pg-ubid) delete-firewall-rule id")

  args 1, invalid_args_message: "rule id is required"

  run do |ubid|
    if ubid.include?("/")
      raise Rodish::CommandFailure, "invalid firewall rule id format"
    end

    delete(project_path("location/#{@location}/postgres/#{@name}/firewall-rule/#{ubid}")) do |data|
      ["Firewall rule, if it exists, has been scheduled for deletion"]
    end
  end
end
