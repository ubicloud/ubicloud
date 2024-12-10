# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes-cluster") do |r|
    r.get do
      kubernetes_cluster_list
    end

    r.on NAME_OR_UBID do |kc_name, kc_id|
      if kc_name
        r.post true do
          post_kubernetes_cluster(kc_name)
        end

        filter = {Sequel[:kubernetes_cluster][:name] => kc_name}
      else
        filter = {Sequel[:kubernetes_cluster][:id] => UBID.to_uuid(kc_id)}
      end

      filter[:location] = @location
      kc = @project.kubernetes_clusters_dataset.first(filter)

      request.get true do
        authorize("KubernetesCluster:view", kc.id)
        @kc = Serializers::KubernetesCluster.serialize(kc)
        if api?
          @kc
        else
          view "kubernetes-cluster/show"
        end
      end
    end
  end
end
