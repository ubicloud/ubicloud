# frozen_string_literal: true

UbiCli.on("fw").run_on("delete-rule") do
  options("ubi fw location/(fw-name|_fw-ubid) delete-rule rule-id")

  args 1

  run do |rule_id|
    raise Rodish::CommandFailure, "invalid rule id format" if rule_id.include?("/")

    delete(fw_path("/firewall-rule/#{rule_id}")) do
      ["Firewall rule, if it existed, has been deleted"]
    end
  end
end
