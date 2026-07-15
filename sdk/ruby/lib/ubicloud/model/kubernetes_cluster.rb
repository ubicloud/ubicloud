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

    def create_nodepool(name, node_size: nil, node_count: nil)
      adapter.post(_path("/nodepool/#{name}"), {node_size:, node_count:}.compact)
    end

    def destroy_nodepool(nodepool_ref)
      adapter.delete(_path("/nodepool/#{nodepool_ref}"))
    end

    def resize_nodepool(nodepool_ref, node_count)
      adapter.post(_path("/nodepool/#{nodepool_ref}/resize"), {node_count:})
    end

    def upgrade_nodepool(nodepool_ref)
      check_no_slash(nodepool_ref, "invalid nodepool reference")
      adapter.post(_path("/nodepool/#{nodepool_ref}/upgrade"))
    end

    def retire_node(node_name)
      adapter.post(_path("/node/#{node_name}/retire"))
    end

    # Upgrade the Kubernetes cluster to the latest available version.
    def upgrade
      merge_into_values(adapter.post(_path("/upgrade")))
    end
  end
end
