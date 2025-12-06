# frozen_string_literal: true

UbiCli.on("fw").run_on("update-description") do
  desc "Update the description for a firewall"

  banner "ubi fw (location/fw-name | fw-id) update-description new-description"

  args 1

  run do |description|
    sdk_object.update_description(description)
    response("Firewall description updated to #{description}")
  end
end
