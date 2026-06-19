# frozen_string_literal: true

class UbiCli
  on("kc").run_on("retire-node") do
    desc "Retire a worker node from a Kubernetes cluster"

    banner "ubi kc (location/kc-name | kc-id) retire-node node-name"

    args 1

    run do |node_name, _, cmd|
      sdk_object.retire_node(node_name)

      response("Retired node #{node_name}.")
    end
  end
end
