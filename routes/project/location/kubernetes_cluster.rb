# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes-cluster") do |r|
    r.get api? do
      kubernetes_cluster_list
    end

    r.on KUBERNETES_CLUSTER_NAME_OR_UBID do |kc_name, kc_id|
      filter = if kc_name
        r.post api? do
          check_visible_location
          kubernetes_cluster_post(kc_name)
        end

        {Sequel[:kubernetes_cluster][:name] => kc_name}
      else
        {Sequel[:kubernetes_cluster][:id] => kc_id}
      end

      filter[:location_id] = @location.id
      kc = @kc = @project.kubernetes_clusters_dataset.first(filter)

      check_found_object(kc)

      r.is do
        r.get do
          authorize("KubernetesCluster:view", kc)
          if api?
            Serializers::KubernetesCluster.serialize(kc, {detailed: true})
          else
            r.redirect kc, "/overview"
          end
        end

        r.delete do
          authorize("KubernetesCluster:delete", kc)
          DB.transaction do
            kc.incr_destroy
            audit_log(kc, "destroy")
          end
          204
        end
      end

      r.rename kc, perm: "KubernetesCluster:edit", serializer: Serializers::KubernetesCluster, template_prefix: "kubernetes-cluster"

      r.show_object(kc, actions: %w[overview nodes settings], perm: "KubernetesCluster:view", template: "kubernetes-cluster/show")

      r.get "kubeconfig" do
        authorize("KubernetesCluster:edit", kc)

        response.content_type = :text
        response["content-disposition"] = "attachment; filename=\"#{kc.name}-kubeconfig.yaml\""
        kc.kubeconfig
      end

      r.on "nodepool" do
        r.on KUBERNETES_NODEPOOL_NAME_OR_UBID do |kn_name, kn_id|
          filter = if kn_name
            {Sequel[:kubernetes_nodepool][:name] => kn_name}
          else
            {Sequel[:kubernetes_nodepool][:id] => kn_id}
          end

          filter[:kubernetes_cluster_id] = kc.id
          kn = @kn = kc.nodepools_dataset.first(filter)

          check_found_object(kn)

          r.post "resize" do
            authorize("KubernetesCluster:edit", kc.id)
            node_count = typecast_params.pos_int!("node_count")
            Validation.validate_kubernetes_worker_node_count(node_count)

            DB.transaction do
              kn.update(node_count:)
              kn.incr_scale_worker_count
              audit_log(kn, "update")
            end

            Serializers::KubernetesCluster.serialize(kc, {detailed: true})
          end
        end
      end
    end
  end
end
