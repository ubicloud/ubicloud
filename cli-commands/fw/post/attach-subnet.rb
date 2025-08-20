# frozen_string_literal: true

UbiCli.on("fw").run_on("attach-subnet") do
  desc "Attach a private subnet to a firewall"

  banner "ubi fw (location/fw-name | fw-id) attach-subnet (ps-name | ps-id)"

  args 1

  run do |subnet_id|
    id = sdk_object.attach_subnet(convert_name_to_id(sdk.private_subnet, subnet_id)).id
    response("Attached private subnet #{subnet_id} to firewall with id #{id}")
  end
end
