# frozen_string_literal: true

UbiCli.on("fw").run_on("add-rule") do
  desc "Add a firewall rule"

  options("ubi fw (location/fw-name | fw-id) add-rule [options] cidr", key: :fw_add_rule) do
    on("-s", "--start-port=port", Integer, "starting (or only) port to allow (default: 0)")
    on("-e", "--end-port=port", Integer, "ending port to allow (default: 65535)")
    on("-d", "--description=desc", "description of rule")
  end

  args 1

  run do |cidr, opts|
    opts = opts[:fw_add_rule]
    start_port, end_port = opts.values_at(:"start-port", :"end-port")
    id = sdk_object.add_rule(cidr, start_port:, end_port:, description: opts[:description])[:id]
    response("Added firewall rule with id: #{id}")
  end
end
