# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes-cluster") do |r|
    r.web do
      r.on KUBERNETES_CLUSTER_NAME_OR_UBID do |kc_name, kc_ubid|
        filter = if kc_name
          {Sequel[:kubernetes_cluster][:name] => kc_name}
        else
          {Sequel[:kubernetes_cluster][:id] => UBID.to_uuid(kc_ubid)}
        end

        filter[:location_id] = @location.id
        kc = @project.kubernetes_clusters_dataset.first(filter)

        next 404 unless kc

        r.get true do
          authorize("KubernetesCluster:view", kc.id)

          @kc = kc
          view "kubernetes-cluster/show"
        end

        r.delete true do
          authorize("KubernetesCluster:delete", kc.id)
          kc.incr_destroy
          204
        end

        r.get "kubeconfig" do
          authorize("KubernetesCluster:edit", kc.id)

          response["Content-Type"] = "text/plain"
          response["Content-Disposition"] = "attachment; filename=\"#{kc.name}-kubeconfig.yaml\""
          kc.kubeconfig
        end
      end
    end
  end
end
