# frozen_string_literal: true

class UbiCli
  on("vm").run_on("serial-log") do
    desc "Show a virtual machine's serial console log, fetching it if needed"

    banner "ubi vm (location/vm-name | vm-id) serial-log [options]"

    options("ubi vm (location/vm-name | vm-id) serial-log [options]", key: :serial_log) do
      on("-r", "--refresh", "request a new fetch even if a recent result exists")
    end

    run do |opts, _cmd|
      rc = sdk_object.serial_log(refresh: opts[:serial_log][:refresh])

      case rc[:status]
      when "succeeded"
        response(rc[:output] || "")
      when "failed"
        response("Failed to fetch serial console log.")
      else
        response("Fetching serial console log, run this command again in a few seconds to see the result.")
      end
    end
  end
end
