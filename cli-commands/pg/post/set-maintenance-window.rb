# frozen_string_literal: true

UbiCli.on("pg").run_on("set-maintenance-window") do
  desc "Set the maintenance window for a PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) set-maintenance-window start-hour"

  help_example "ubi pg pg-id set-maintenance-window 3   #  3 am"
  help_example "ubi pg pg-id set-maintenance-window 23  # 11 pm"
  help_example "ubi pg pg-id set-maintenance-window \"\"  # unset"

  args 1

  run do |hour|
    hour = nil if hour.empty?
    if (start = sdk_object.set_maintenance_window(hour).maintenance_window_start_at)
      response("Starting hour for maintenance window for PostgreSQL database with id #{sdk_object.id} set to #{start}.")
    else
      response("Unset maintenance window for PostgreSQL database with id #{sdk_object.id}.")
    end
  end
end
