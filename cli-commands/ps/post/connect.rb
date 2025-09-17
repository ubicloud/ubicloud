# frozen_string_literal: true

UbiCli.on("ps").run_on("connect") do
  desc "Connect a private subnet to another private subnet"

  options("ubi ps (location/ps-name | ps-id) connect [options] (location/ps-name | ps-id)") do
    on("-P", "--postgres", "treat argument as PostgreSQL database name or id")
  end

  args 1

  run do |ps_id, opts|
    connect_id = if opts[:postgres]
      prefix = "PostgreSQL database "
      convert_name_to_id(sdk.postgres, ps_id)
    else
      convert_loc_name_to_id(sdk.private_subnet, ps_id)
    end
    id = sdk_object.connect(connect_id).id
    response("Connected #{prefix}private subnet #{ps_id} to #{id}")
  end
end
