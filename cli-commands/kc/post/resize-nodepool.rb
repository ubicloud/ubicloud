# frozen_string_literal: true

UbiCli.on("kc").run_on("resize-nodepool") do
  desc "Resize a Kubernetes cluster nodepool"

  banner "ubi kc (location/kc-name | kc-id) resize-nodepool (np-name | np-id) node-count"

  args 2

  run do |nodepool_ref, node_count, _, cmd|
    node_count = Integer(node_count, exception: false)

    unless node_count&.>(0)
      cmd.raise_failure("the node count must be a positive integer")
    end

    sdk_object.resize_nodepool(nodepool_ref, node_count)

    response("Resized nodepool #{nodepool_ref} to #{node_count} nodes.")
  end
end
