# frozen_string_literal: true

UbiCli.on("mi").run_on("set-latest") do
  desc "Set the latest version of a machine image"

  banner "ubi mi (location/mi-name | mi-id) set-latest version"

  args 1

  run do |version|
    sdk_object.set_latest_version(version)
    response("Machine image latest version set to #{version}")
  end
end
