# frozen_string_literal: true

class UbiCli
  on("pg").run_on("set-backup-schedule") do
    desc "Set the backup schedule for a PostgreSQL database"

    options("ubi pg (location/pg-name | pg-id) set-backup-schedule [options]", key: :pg_set_backup_schedule) do
      on("-p", "--period=hours", "hours between backups (1-168)")
      on("-s", "--start=hour", "UTC hour a backup slot opens (0-23), or empty for any time")
      on("-r", "--retention=days", "point-in-time recovery window in days (1-35)")
    end

    help_example "ubi pg pg-id set-backup-schedule -s 3          # backup slot opens at 3 am UTC"
    help_example "ubi pg pg-id set-backup-schedule -s \"\"         # backups start at any time"
    help_example "ubi pg pg-id set-backup-schedule -p 12 -r 14   # every 12 hours, restore up to 14 days back"

    args 0

    run do |opts|
      params = underscore_keys(opts[:pg_set_backup_schedule])
      kwargs = {}
      kwargs[:period_hours] = params[:period] if params[:period]
      kwargs[:retention_days] = params[:retention] if params[:retention]
      kwargs[:start_hour] = (params[:start].empty? ? nil : params[:start]) if params[:start]
      pg = sdk_object.set_backup_schedule(**kwargs)
      response("Backup schedule for PostgreSQL database with id #{pg.id} updated: every #{pg.backup_period_hours} hours, " \
        "#{pg.backup_window_start_at ? "window opens at #{pg.backup_window_start_at}:00 UTC" : "any start time"}, " \
        "point-in-time recovery for #{pg.backup_retention_days} days.")
    end
  end
end
