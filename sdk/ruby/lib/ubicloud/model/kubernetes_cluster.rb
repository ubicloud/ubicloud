# frozen_string_literal: true

module Ubicloud
  class KubernetesCluster < Model
    set_prefix "kc"

    set_fragment "kubernetes-cluster"

    set_columns :id, :name, :state, :location

    # Return string with the contents of kubeconfig.yaml for the Kubernetes cluster.
    def kubeconfig
      adapter.get(_path("/kubeconfig"))
    end
  end
end
