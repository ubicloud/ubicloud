# frozen_string_literal: true

UbiCli.on("vm").run_on("restart") do
  desc "Restart a virtual machine"

  banner "ubi vm (location/vm-name | vm-id) restart"

  run do
    id = sdk_object.restart.id
    response("Scheduled restart of VM with id #{id}")
  end
end
