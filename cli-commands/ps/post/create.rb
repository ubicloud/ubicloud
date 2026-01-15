# frozen_string_literal: true

UbiCli.on("ps").run_on("create") do
  desc "Create a private subnet"

  options("ubi ps location/ps-name create [options]", key: :ps_create) do
    on("-f", "--firewall-id=fw-id-or-name", "add to given firewall")
  end

  run do |opts|
    params = underscore_keys(opts[:ps_create])
    if params[:firewall_id]
      params[:firewall_id] = convert_name_to_id(sdk.firewall, params[:firewall_id])
    end
    id = sdk.private_subnet.create(location: @location, name: @name, **params).id
    response("Private subnet created with id: #{id}")
  end
end
