# frozen_string_literal: true

UbiCli.on("fw").run_on("add-rule") do
  options("ubi fw location/(fw-name|_fw-ubid) add-rule cidr", key: :fw_add_rule) do
    on("-s", "--start-port=port", "starting (or only) port to allow (default: 0)")
    on("-e", "--end-port=port", "ending port to allow (default: 65535)")
  end

  args 1

  run do |cidr, opts|
    range = opts[:fw_add_rule].values_at(:"start-port", :"end-port")
    range[1] ||= range[0] || 65535
    range[0] ||= 0
    post(fw_path("/firewall-rule"), "cidr" => cidr, "port_range" => range.join("..")) do |data|
      ["Added firewall rule with id: #{data["id"]}"]
    end
  end
end
