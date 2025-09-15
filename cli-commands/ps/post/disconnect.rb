# frozen_string_literal: true

UbiCli.on("ps").run_on("disconnect") do
  desc "Disconnect a private subnet from another private subnet"

  options("ubi ps (location/ps-name | ps-id) disconnect [options] (ps-name | ps-id)") do
    on("-P", "--postgres", "treat argument as PostgreSQL database name or id")
  end

  args 1

  run do |arg, opts, cmd|
    model_adapter = if opts[:postgres]
      prefix = "PostgreSQL database "
      sdk.postgres
    else
      sdk.private_subnet
    end
    ps_id = convert_name_to_id(model_adapter, arg)
    check_no_slash(ps_id, "invalid private subnet id format", cmd)
    id = sdk_object.disconnect(ps_id).id
    response("Disconnected #{prefix}private subnet #{arg} from #{id}")
  end
end
