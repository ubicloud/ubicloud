# frozen_string_literal: true

UbiCli.on("ps").run_on("connect") do
  desc "Connect a private subnet to another private subnet"

  options("ubi ps (location/ps-name | ps-id) connect [options] (ps-name | ps-id)") do
    on("-P", "--postgres", "treat argument as PostgreSQL database name or id")
  end

  args 1

  run do |ps_id, opts|
    model_adapter = if opts[:postgres]
      prefix = "PostgreSQL database "
      sdk.postgres
    else
      sdk.private_subnet
    end
    id = sdk_object.connect(convert_name_to_id(model_adapter, ps_id)).id
    response("Connected #{prefix}private subnet #{ps_id} to #{id}")
  end
end
