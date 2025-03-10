# frozen_string_literal: true

UbiCli.on("ps").run_on("create") do
  desc "Create a private subnet"

  options("ubi ps location/ps-name create [options]", key: :ps_create) do
    on("-f", "--firewall-id=id", "add to given firewall")
  end

  run do |opts|
    params = underscore_keys(opts[:ps_create])
    post(ps_path, params) do |data|
      ["Private subnet created with id: #{data["id"]}"]
    end
  end
end
