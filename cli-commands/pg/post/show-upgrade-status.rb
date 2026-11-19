# frozen_string_literal: true

class UbiCli
  on("pg").run_on("show-upgrade-status") do
    desc "Show the status of a major version upgrade of the PostgreSQL database"

    banner "ubi pg (location/pg-name | pg-id) show-upgrade-status"

    run do
      upgrade_status = sdk_object.upgrade_status
      body = []
      body << "Major version upgrade of PostgreSQL database #{sdk_object.id} to version #{upgrade_status[:target_version]}\n"
      body << "Status: #{upgrade_status[:upgrade_status]}\n"
      body << "Stage: #{upgrade_status[:upgrade_stage] || "N/A"}\n"
      if upgrade_status[:upgrade_status] == "failed"
        logs_cmd = "ubi pg #{@location}/#{@name} get-logs --stream-name upgrade -l 500"
        if (failed_at = upgrade_status[:upgrade_failed_at])
          failed_at = Time.parse(failed_at)
          logs_cmd << " --start #{(failed_at - 60 * 60).utc.iso8601} --end #{(failed_at + 60).utc.iso8601}"
        end
        body << "\nTo find the cause of the failure, see the upgrade logs:\n  #{logs_cmd}\n"
        body << "After you fix the cause, reset the upgrade to try again:\n  ubi pg #{@location}/#{@name} reset-upgrade\n"
      end
      response(body)
    end
  end
end
