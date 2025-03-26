# frozen_string_literal: true

UbiCli.on("fw").run_on("create") do
  desc "Create a firewall"

  options("ubi fw location/fw-name create [options]", key: :fw_create) do
    on("-d", "--description=desc", "description for firewall")
  end

  run do |opts|
    params = underscore_keys(opts[:fw_create])
    id = sdk.firewall.create(location: @location, name: @name, **params).id
    response("Firewall created with id: #{id}")
  end
end
