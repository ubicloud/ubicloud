# frozen_string_literal: true

UbiCli.on("pg").run_on("modify-firewall-rule") do
  desc "Modify a PostgreSQL firewall rule"

  options("ubi pg (location/pg-name | pg-id) modify-firewall-rule [options] rule-id", key: :pg_fw_mod) do
    on("-c", "--cidr=cidr", "ip range to allow in cidr format (e.g. 1.2.3.0/24)")
    on("-d", "--description=desc", "description of rule")
  end

  args 1

  run do |ubid, opts, cmd|
    check_no_slash(ubid, "invalid firewall rule id format", cmd)
    params = opts[:pg_fw_mod]
    data = sdk_object.modify_firewall_rule(ubid, cidr: params[:cidr], description: params[:description])
    response("PostgreSQL database firewall rule modified.\n  rule id: #{data[:id]}\n  cidr: #{data[:cidr]}\n  description: #{data[:description].inspect}")
  end
end
