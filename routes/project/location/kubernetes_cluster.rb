# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes-cluster") do |r|
    r.web do
      r.on NAME_OR_UBID do |kc_name, kc_ubid|
        filter = if kc_name
          {Sequel[:kubernetes_cluster][:name] => kc_name}
        else
          {Sequel[:kubernetes_cluster][:id] => UBID.to_uuid(kc_ubid)}
        end

        filter[:location] = @location
        kc = @project.kubernetes_clusters_dataset.first(filter)

        next 404 unless kc

        r.get true do
          authorize("KubernetesCluster:view", kc.id)

          @kc = Serializers::KubernetesCluster.serialize(kc)
          view "kubernetes-cluster/show"
        end

        r.delete true do
          authorize("KubernetesCluster:delete", kc.id)
          kc.incr_destroy
          204
        end
      end
    end
  end
end
