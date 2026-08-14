# frozen_string_literal: true

class UbiCli
  on("vm").run_on("set-maintenance-window") do
    desc "Set the maintenance window for a virtual machine"

    options("ubi vm (location/vm-name | vm-id) set-maintenance-window [options] start-hour", key: :vm_set_maintenance_window) do
      on("-d", "--days=days", "days of week the window applies (e.g. mon,wed,fri); default every day")
    end

    help_example "ubi vm vm-id set-maintenance-window 3   #  3 am"
    help_example "ubi vm vm-id set-maintenance-window 23  # 11 pm"
    help_example "ubi vm vm-id set-maintenance-window \"\"  # unset"
    help_example "ubi vm vm-id set-maintenance-window -d mon,wed 3  # 3 am, Mon & Wed"
    help_example "ubi vm vm-id set-maintenance-window -d \"\" 3  # 3 am, clear days (every day)"

    args 1

    run do |hour, opts|
      params = underscore_keys(opts[:vm_set_maintenance_window])
      hour = nil if hour.empty?
      days = params[:days]&.split(",")
      if (start = sdk_object.set_maintenance_window(hour, days:).maintenance_window_start_at)
        on_days_msg = " on #{days.join(", ")}" if days && !days.empty?
        response("Starting hour for maintenance window for virtual machine with id #{sdk_object.id} set to #{start}#{on_days_msg}.")
      else
        response("Unset maintenance window for virtual machine with id #{sdk_object.id}.")
      end
    end
  end
end
