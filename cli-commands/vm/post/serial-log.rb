# frozen_string_literal: true

UbiCli.on("vm").run_on("serial-log") do
  desc "Show the serial console log for a virtual machine"

  banner "ubi vm (location/vm-name | vm-id) serial-log"

  run do
    response(sdk_object.serial_log)
  end
end
