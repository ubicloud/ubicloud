# frozen_string_literal: true

UbiRodish.on("pg").run_is("delete-firewall-rule", args: 1, invalid_args_message: "rule id is required") do |ubid|
  if ubid.include?("/")
    raise Rodish::CommandFailure, "invalid firewall rule id format"
  end

  delete(project_path("location/#{@location}/postgres/#{@name}/firewall-rule/#{ubid}")) do |data|
    ["Firewall rule, if it exists, has been scheduled for deletion"]
  end
end
