# frozen_string_literal: true

UbiCli.on("pg").run_on("delete-firewall-rule") do
  desc "Delete a PostgreSQL firewall rule"

  banner "ubi pg (location/pg-name | pg-id) delete-firewall-rule rule-id"

  args 1

  run do |ubid, _, cmd|
    check_no_slash(ubid, "invalid firewall rule id format", cmd)
    sdk_object.delete_firewall_rule(ubid)
    response("Firewall rule, if it exists, has been scheduled for deletion")
  end
end
