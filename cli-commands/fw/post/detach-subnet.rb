# frozen_string_literal: true

UbiCli.on("fw").run_on("detach-subnet") do
  desc "Detch a private subnet from a firewall"

  banner "ubi fw (location/fw-name | fw-id) detach-subnet (ps-name | ps-id)"

  args 1

  run do |subnet_id|
    id = sdk_object.detach_subnet(convert_name_to_id(sdk.private_subnet, subnet_id)).id
    response("Detached private subnet #{subnet_id} from firewall with id #{id}")
  end
end
