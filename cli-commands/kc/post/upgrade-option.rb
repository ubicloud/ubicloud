# frozen_string_literal: true

UbiCli.on("kc").run_on("upgrade-option") do
  desc "Show available upgrade option for a Kubernetes cluster"

  banner "ubi kc (location/kc-name | kc-id) upgrade-option"

  run do
    data = sdk_object.upgrade_option
    body = []
    body << "current-version: " << data[:current_version] << "\n"
    if data[:upgrade_version]
      body << "upgrade-version: " << data[:upgrade_version] << "\n"
    else
      body << "upgrade-version: none\n"
    end
    response(body)
  end
end
