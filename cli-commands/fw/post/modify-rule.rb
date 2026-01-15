# frozen_string_literal: true

UbiCli.on("fw").run_on("modify-rule") do
  desc "Modify a firewall rule"

  options("ubi fw (location/fw-name | fw-id) modify-rule options rule-id", key: :fw_modify_rule) do
    on("-c", "--cidr=ip-range", "IPv4 or IPv6 range to allow")
    on("-s", "--start-port=port", Integer, "starting (or only) port to allow (default: 0)")
    on("-e", "--end-port=port", Integer, "ending port to allow (default: 65535)")
    on("-d", "--description=desc", "description of rule")
  end

  args 1

  run do |rule_id, opts, cmd|
    opts = underscore_keys(opts[:fw_modify_rule])
    if opts.empty?
      raise Rodish::CommandFailure.new("Must provide at least one option (-c, -s, -e, or -d)", cmd)
    end
    id = sdk_object.modify_rule(rule_id, **opts)[:id]
    response("Modified firewall rule with id: #{id}")
  end
end
