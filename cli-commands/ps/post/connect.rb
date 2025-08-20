# frozen_string_literal: true

UbiCli.on("ps").run_on("connect") do
  desc "Connect a private subnet to another private subnet"

  banner "ubi ps (location/ps-name | ps-id) connect (location/ps-name | ps-id)"

  args 1

  run do |ps_id|
    id = sdk_object.connect(convert_loc_name_to_id(sdk.private_subnet, ps_id)).id
    response("Connected private subnet #{ps_id} to #{id}")
  end
end
