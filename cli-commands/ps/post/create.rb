# frozen_string_literal: true

UbiCli.on("ps").run_on("create") do
  desc "Create a private subnet"

  options("ubi ps location/ps-name create [options]", key: :ps_create) do
    on("-f", "--firewall-id=id", "add to given firewall")
  end

  run do |opts|
    params = underscore_keys(opts[:ps_create])
    id = sdk.private_subnet.create(location: @location, name: @name, **params).id
    response("Private subnet created with id: #{id}")
  end
end
