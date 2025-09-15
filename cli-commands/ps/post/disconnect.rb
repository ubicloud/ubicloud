# frozen_string_literal: true

UbiCli.on("ps").run_on("disconnect") do
  desc "Disconnect a private subnet from another private subnet"

  banner "ubi ps (location/ps-name | ps-id) disconnect (ps-name | ps-id)"

  args 1

  run do |ps_id, _, cmd|
    arg = ps_id
    ps_id = convert_name_to_id(sdk.private_subnet, ps_id)
    check_no_slash(ps_id, "invalid private subnet id format", cmd)
    id = sdk_object.disconnect(ps_id).id
    response("Disconnected private subnet #{arg} from #{id}")
  end
end
