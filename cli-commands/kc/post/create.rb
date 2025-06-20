# frozen_string_literal: true

UbiCli.on("kc").run_on("create") do
  desc "Create a Kubernetes cluster"

  options("ubi kc location/kc-name create [options]", key: :kc_create) do
    on("-v", "--version=version", "Kubernetes version")
    on("-c", "--cp-node-count=count", Integer, "Control plane node count")
    on("-w", "--worker-node-count=count", Integer, "Worker node count")
    on("-z", "--worker-size=size", "Worker size")
  end
  help_option_values("Version:", Option.kubernetes_versions)
  help_option_values("Control Plane Node Count:", Option::KubernetesCPOptions.map(&:cp_node_count))

  run do |opts|
    params = underscore_keys(opts[:kc_create])
    params[:cp_nodes] = params.delete(:cp_node_count)
    params[:worker_nodes] = params.delete(:worker_node_count)
    id = sdk.kubernetes_cluster.create(location: @location, name: @name, **params).id
    response("Kubernetes cluster created with id: #{id}")
  end
end
