# frozen_string_literal: true

UbiCli.on("pg").run_on("add-firewall-rule") do
  desc "Add a PostgreSQL firewall rule"

  options("ubi pg (location/pg-name | pg-id) add-firewall-rule [options] cidr", key: :pg_fw_rule) do
    on("-d", "--description=desc", "description of rule")
  end

  args 1

  run do |cidr, opts|
    data = sdk_object.add_firewall_rule(cidr, description: opts[:pg_fw_rule][:description])
    response("Firewall rule added to PostgreSQL database.\n  rule id: #{data[:id]}\n  cidr: #{data[:cidr]}\n  description: #{data[:description].inspect}")
  end
end
