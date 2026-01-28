# frozen_string_literal: true

UbiCli.on("vm").run_on("stop") do
  desc "Stop a virtual machine"

  banner "ubi vm (location/vm-name | vm-id) stop"

  run do
    id = sdk_object.stop.id
    response(<<END)
Scheduled stop of VM with id #{id}.
Note that stopped VMs still accrue billing charges. To stop billing charges,
destroy the VM.
END
  end
end
