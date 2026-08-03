# frozen_string_literal: true

class UbiCli
  on("vm").run_on("show-serial-log") do
    desc "Show a virtual machine's most recently fetched serial console log"

    banner "ubi vm (location/vm-name | vm-id) show-serial-log"

    run do
      rc = sdk_object.serial_console

      case rc[:status]
      when "succeeded"
        response(rc[:output] || "")
      when "failed"
        response("Failed to fetch serial console log: #{rc[:output]}")
      when "created"
        response("Fetching serial console log, run this command again in a few seconds to see the result.")
      else
        response("No serial console log has been fetched yet. Run `fetch-serial-log` first.")
      end
    end
  end
end
