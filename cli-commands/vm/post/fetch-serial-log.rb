# frozen_string_literal: true

class UbiCli
  on("vm").run_on("fetch-serial-log") do
    desc "Request a fetch of a virtual machine's serial console log"

    banner "ubi vm (location/vm-name | vm-id) fetch-serial-log"

    run do
      sdk_object.fetch_serial_console
      response("Fetching serial console log, run `show-serial-log` in a few seconds to see the result.")
    end
  end
end
