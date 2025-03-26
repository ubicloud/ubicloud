# frozen_string_literal: true

UbiCli.on("ps").run_on("connect") do
  desc "Connect a private subnet to another private subnet"

  banner "ubi ps (location/ps-name | ps-id) connect ps-id"

  args 1

  run do |ps_id|
    id = sdk_object.connect(ps_id).id
    response("Connected private subnets with ids #{ps_id} and #{id}")
  end
end
