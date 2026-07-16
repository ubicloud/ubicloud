# frozen_string_literal: true

class UbiCli
  on("kc").run_on("upgrade-nodepool") do
    desc "Upgrade a nodepool of a Kubernetes cluster to the cluster's version"

    banner "ubi kc (location/kc-name | kc-id) upgrade-nodepool (np-name | np-id)"

    args 1

    run do |np_ref, _, cmd|
      check_no_slash(np_ref, "invalid nodepool name", cmd)
      data = sdk_object.upgrade_nodepool(np_ref)
      response("Scheduled version upgrade of nodepool #{data[:name]} to version #{data[:version]}.")
    end
  end
end
