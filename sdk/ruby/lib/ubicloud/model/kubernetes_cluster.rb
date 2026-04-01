# frozen_string_literal: true

module Ubicloud
  class KubernetesCluster < Model
    set_prefix "kc"

    set_fragment "kubernetes-cluster"

    set_columns :id, :name, :state, :location, :version

    # Return string with the contents of kubeconfig.yaml for the Kubernetes cluster.
    def kubeconfig
      adapter.get(_path("/kubeconfig"))
    end

    def resize_nodepool(nodepool_ref, node_count)
      adapter.post(_path("/nodepool/#{nodepool_ref}/resize"), {node_count:})
    end

    # Upgrade the Kubernetes cluster to the latest available version.
    def upgrade
      merge_into_values(adapter.post(_path("/upgrade")))
    end
  end
end
