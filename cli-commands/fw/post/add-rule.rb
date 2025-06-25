# frozen_string_literal: true

UbiCli.on("fw").run_on("add-rule") do
  desc "Add a firewall rule"

  options("ubi fw (location/fw-name | fw-id) add-rule cidr", key: :fw_add_rule) do
    on("-s", "--start-port=port", Integer, "starting (or only) port to allow (default: 0)")
    on("-e", "--end-port=port", Integer, "ending port to allow (default: 65535)")
  end

  args 1

  run do |cidr, opts|
    start_port, end_port = opts[:fw_add_rule].values_at(:"start-port", :"end-port")
    id = sdk_object.add_rule(cidr, start_port:, end_port:)[:id]
    response("Added firewall rule with id: #{id}")
  end
end
