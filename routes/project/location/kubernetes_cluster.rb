# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes-cluster") do |r|
    r.get api? do
      kubernetes_cluster_list
    end

    r.on KUBERNETES_CLUSTER_NAME_OR_UBID do |kc_name, kc_ubid|
      filter = if kc_name
        r.post api? do
          check_visible_location
          kubernetes_cluster_post(kc_name)
        end

        {Sequel[:kubernetes_cluster][:name] => kc_name}
      else
        {Sequel[:kubernetes_cluster][:id] => UBID.to_uuid(kc_ubid)}
      end

      filter[:location_id] = @location.id
      kc = @project.kubernetes_clusters_dataset.first(filter)

      check_found_object(kc)

      r.is do
        r.get do
          authorize("KubernetesCluster:view", kc.id)
          if api?
            Serializers::KubernetesCluster.serialize(kc, {detailed: true})
          else
            @kc = kc
            view "kubernetes-cluster/show"
          end
        end

        r.delete do
          authorize("KubernetesCluster:delete", kc.id)
          DB.transaction do
            kc.incr_destroy
            audit_log(kc, "destroy")
          end
          204
        end
      end

      r.get "kubeconfig" do
        authorize("KubernetesCluster:edit", kc.id)

        response["content-type"] = "text/plain"
        response["content-disposition"] = "attachment; filename=\"#{kc.name}-kubeconfig.yaml\""
        kc.kubeconfig
      end
    end
  end
end
