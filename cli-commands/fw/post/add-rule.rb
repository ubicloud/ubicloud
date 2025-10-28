# frozen_string_literal: true

UbiCli.on("fw").run_on("add-rule") do
  desc "Add a firewall rule"

  options("ubi fw (location/fw-name | fw-id) add-rule [options] (cidr | ps-id | ps-name)", key: :fw_add_rule) do
    on("-s", "--start-port=port", Integer, "starting (or only) port to allow (default: 0)")
    on("-e", "--end-port=port", Integer, "ending port to allow (default: 65535)")
    on("-d", "--description=desc", "description of rule")
  end

  args 1

  run do |cidr, opts|
    body = sdk_object.add_rule(cidr, **underscore_keys(opts[:fw_add_rule]))

    if body.is_a?(Array)
      response("Added firewall rules with ids: #{body.map { it[:id] }.join(" ")}")
    else
      response("Added firewall rule with id: #{body[:id]}")
    end
  end
end
