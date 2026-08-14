# frozen_string_literal: true

class UbiCli
  on("vm").run_on("set-maintenance-window") do
    desc "Set the maintenance window for a virtual machine"

    banner "ubi vm (location/vm-name | vm-id) set-maintenance-window start-hour"

    help_example "ubi vm vm-id set-maintenance-window 3   #  3 am"
    help_example "ubi vm vm-id set-maintenance-window 23  # 11 pm"
    help_example "ubi vm vm-id set-maintenance-window \"\"  # unset"

    args 1

    run do |hour|
      hour = nil if hour.empty?
      if (start = sdk_object.set_maintenance_window(hour).maintenance_window_start_at)
        response("Starting hour for maintenance window for virtual machine with id #{sdk_object.id} set to #{start}.")
      else
        response("Unset maintenance window for virtual machine with id #{sdk_object.id}.")
      end
    end
  end
end
