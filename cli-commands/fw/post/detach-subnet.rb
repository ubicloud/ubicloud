# frozen_string_literal: true

UbiCli.on("fw").run_on("detach-subnet") do
  desc "Detch a private subnet from a firewall"

  banner "ubi fw (location/fw-name | fw-id) detach-subnet ps-id"

  args 1

  run do |subnet_id|
    id = sdk_object.detach_subnet(subnet_id).id
    response("Detached private subnet with id #{subnet_id} from firewall with id #{id}")
  end
end
