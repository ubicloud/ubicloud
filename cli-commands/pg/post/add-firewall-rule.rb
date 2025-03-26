# frozen_string_literal: true

UbiCli.on("pg").run_on("add-firewall-rule") do
  desc "Add a PostgreSQL firewall rule"

  banner "ubi pg (location/pg-name | pg-id) add-firewall-rule cidr"

  args 1

  run do |cidr|
    data = sdk_object.add_firewall_rule(cidr)
    response("Firewall rule added to PostgreSQL database.\n  rule id: #{data[:id]}, cidr: #{data[:cidr]}")
  end
end
