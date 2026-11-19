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
      body << "Error: #{upgrade_status[:upgrade_error]}\n" if upgrade_status[:upgrade_error]
      (upgrade_status[:upgrade_error_details] || []).each do |detail|
        body << "#{detail.map { |label, value| "#{label}: #{value}" }.join(", ")}\n"
      end
      if upgrade_status[:upgrade_status] == "failed"
        logs_cmd = "ubi pg #{@location}/#{@name} get-logs --stream-name upgrade -l 500"
        if (logs_start = upgrade_status[:upgrade_logs_start])
          logs_cmd << " --start #{logs_start} --end #{upgrade_status[:upgrade_logs_end]}"
        end
        body << "\nTo find the cause of the failure, see the upgrade logs:\n  #{logs_cmd}\n"
      end
      response(body)
    end
  end
end
