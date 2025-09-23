# frozen_string_literal: true

UbiCli.on("pg").run_on("show-upgrade-status") do
  desc "Show the status of a major version upgrade of the PostgreSQL database"

  banner "ubi pg (location/pg-name | pg-id) show-upgrade-status"

  run do
    upgrade_status = sdk_object.upgrade_status
    body = []
    body << "Major version upgrade of PostgreSQL database #{sdk_object.id} to version #{upgrade_status[:target_version]}\n"
    body << "Status: #{upgrade_status[:upgrade_status]}\n"
    response(body)
  end
end
