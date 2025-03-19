# frozen_string_literal: true

UbiCli.on("ps").run_on("disconnect") do
  desc "Disconnect a private subnet from another private subnet"

  banner "ubi ps (location/ps-name | ps-id) disconnect ps-id"

  args 1

  run do |ps_id|
    check_no_slash(ps_id, "invalid private subnet id format")
    id = sdk_object.disconnect(ps_id).id
    response("Disconnected private subnets with ids #{ps_id} and #{id}")
  end
end
