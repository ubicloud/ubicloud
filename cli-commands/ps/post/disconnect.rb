# frozen_string_literal: true

UbiCli.on("ps").run_on("disconnect") do
  desc "Disconnect a private subnet from another private subnet"

  options("ubi ps (location/ps-name | ps-id) disconnect [options] (location/ps-name | ps-id)") do
    on("-P", "--postgres", "treat argument as PostgreSQL database name or id")
  end

  args 1

  run do |arg, opts, cmd|
    ps_id = if opts[:postgres]
      prefix = "PostgreSQL database "
      convert_name_to_id(sdk.postgres, arg)
    else
      convert_loc_name_to_id(sdk.private_subnet, arg)
    end
    check_no_slash(ps_id, "invalid private subnet id format", cmd)
    id = sdk_object.disconnect(ps_id).id
    response("Disconnected #{prefix}private subnet #{arg} from #{id}")
  end
end
