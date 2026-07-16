# frozen_string_literal: true

class UbiCli
  on("kc").run_on("create-nodepool") do
    desc "Create a nodepool on a Kubernetes cluster"

    banner "ubi kc (location/kc-name | kc-id) create-nodepool np-name node-size node-count"

    args 3

    run do |np_name, node_size, node_count, _, cmd|
      check_no_slash(np_name, "invalid nodepool name", cmd)
      node_count = Integer(node_count, 10, exception: false)

      unless node_count&.>(0)
        cmd.raise_failure("the node count must be a positive integer")
      end

      data = sdk_object.create_nodepool(np_name, node_size:, node_count:)
      response("Kubernetes nodepool created with id: #{data[:id]}")
    end
  end
end
