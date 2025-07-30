# frozen_string_literal: true

UbiCli.on("kc").run_on("kubeconfig") do
  desc "Print kubeconfig.yaml for a Kubernetes cluster"

  banner "ubi kc (location/kc-name | kc-id) kubeconfig"

  run do
    response(sdk_object.kubeconfig)
  end
end
