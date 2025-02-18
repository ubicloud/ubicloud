# frozen_string_literal: true

UbiCli.on("fw").run_on("create") do
  options("ubi fw location/fw-name create [options]", key: :fw_create) do
    on("-d", "--description=desc", "description for firewall")
  end

  run do |opts|
    params = underscore_keys(opts[:fw_create])
    post(fw_path, params) do |data|
      ["Firewall created with id: #{data["id"]}"]
    end
  end
end
