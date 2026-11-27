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
      response(body)
    end
  end
end
