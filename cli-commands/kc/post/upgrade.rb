# frozen_string_literal: true

UbiCli.on("kc").run_on("upgrade") do
  desc "Upgrade a Kubernetes cluster to the next supported version"

  banner "ubi kc (location/kc-name | kc-id) upgrade"

  run do |opts, cmd|
    data = sdk_object.upgrade
    response("Scheduled version upgrade of Kubneretes cluster with id #{data.id} to version #{data.version}.")
  end
end
