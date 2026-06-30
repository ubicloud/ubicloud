# frozen_string_literal: true

class UbiCli
  on("pg").run_on("set-maintenance-window") do
    desc "Set the maintenance window for a PostgreSQL database"

    options("ubi pg (location/pg-name | pg-id) set-maintenance-window [options] start-hour", key: :pg_set_maintenance_window) do
      on("-d", "--days=days", "days of week the window applies (e.g. mon,wed,fri); default every day")
      on("-p", "--platform-only", "limit the window to platform maintenance only")
    end

    help_example "ubi pg pg-id set-maintenance-window 3   #  3 am"
    help_example "ubi pg pg-id set-maintenance-window 23  # 11 pm"
    help_example "ubi pg pg-id set-maintenance-window \"\"  # unset"
    help_example "ubi pg pg-id set-maintenance-window -d mon,wed -p 3  # platform-only, Mon & Wed"

    args 1

    run do |hour, opts|
      params = underscore_keys(opts[:pg_set_maintenance_window])
      hour = nil if hour.empty?
      days = params[:days]&.split(",")
      platform_only = params[:platform_only] || false
      if (start = sdk_object.set_maintenance_window(hour, days:, platform_only:).maintenance_window_start_at)
        response("Starting hour for maintenance window for PostgreSQL database with id #{sdk_object.id} set to #{start}.")
      else
        response("Unset maintenance window for PostgreSQL database with id #{sdk_object.id}.")
      end
    end
  end
end
