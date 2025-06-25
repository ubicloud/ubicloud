# frozen_string_literal: true

UbiCli.on("fw").run_on("delete-rule") do
  desc "Remove a firewall rule"

  banner "ubi fw (location/fw-name | fw-id) delete-rule rule-id"

  args 1

  run do |rule_id, _, cmd|
    check_no_slash(rule_id, "invalid rule id format", cmd)
    sdk_object.delete_rule(rule_id)
    response("Firewall rule, if it existed, has been deleted")
  end
end
