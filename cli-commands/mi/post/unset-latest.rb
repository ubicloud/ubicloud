# frozen_string_literal: true

UbiCli.on("mi").run_on("unset-latest") do
  desc "Unset the latest version of a machine image"

  banner "ubi mi (location/mi-name | mi-id) unset-latest"

  run do
    sdk_object.set_latest_version(nil)
    response("Machine image latest version unset")
  end
end
