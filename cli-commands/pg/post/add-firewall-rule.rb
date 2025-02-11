# frozen_string_literal: true

UbiRodish.on("pg").run_is("add-firewall-rule", args: 1, invalid_args_message: "cidr is required") do |cidr|
  post(project_path("location/#{@location}/postgres/#{@name}/firewall-rule"), "cidr" => cidr) do |data|
    ["Firewall rule added to PostgreSQL database.\n  rule id: #{data["id"]}, cidr: #{data["cidr"]}"]
  end
end
