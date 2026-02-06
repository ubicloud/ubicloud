# frozen_string_literal: true

UbiCli.on("vm").run_on("start") do
  desc "Start a virtual machine"

  banner "ubi vm (location/vm-name | vm-id) start"

  run do
    id = sdk_object.start.id
    response("Scheduled start of VM with id #{id}")
  end
end
