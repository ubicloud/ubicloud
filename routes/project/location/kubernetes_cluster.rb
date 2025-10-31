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

      r.rename kc, perm: "KubernetesCluster:edit", serializer: Serializers::KubernetesCluster, template: "kubernetes-cluster/show"

      r.show_object(kc, actions: %w[overview nodes settings], perm: "KubernetesCluster:view", template: "kubernetes-cluster/show")

      r.get "kubeconfig" do
        authorize("KubernetesCluster:edit", kc)

        response.content_type = :text
        response["content-disposition"] = "attachment; filename=\"#{kc.name}-kubeconfig.yaml\""
        kc.kubeconfig
      end

      r.post "nodepool", KUBERNETES_NODEPOOL_NAME_OR_UBID, "resize" do |kn_name, kn_id|
        filter = if kn_name
          {Sequel[:kubernetes_nodepool][:name] => kn_name}
        else
          {Sequel[:kubernetes_nodepool][:id] => kn_id}
        end

        filter[:kubernetes_cluster_id] = kc.id
        kn = @kn = kc.nodepools_dataset.first(filter)

        check_found_object(kn)

        authorize("KubernetesCluster:edit", kc.id)
        handle_validation_failure("kubernetes-cluster/show") { @page = "settings" }
        node_count = typecast_params.pos_int!("node_count")
        Validation.validate_kubernetes_worker_node_count(node_count)

        if node_count > kn.node_count
          node_size = Validation.validate_vm_size(kn.target_node_size, "x64")
          extra_vcpu_count = (node_count - kn.node_count) * node_size.vcpus

          Validation.validate_vcpu_quota(@project, "KubernetesVCpu", extra_vcpu_count, name: :node_count)
        end

        DB.transaction do
          kn.update(node_count:)
          kn.incr_scale_worker_count
          audit_log(kn, "update")
        end

        if api?
          Serializers::KubernetesNodepool.serialize(kn, {detailed: true})
        else
          flash["notice"] = "#{kc.name} node pool #{kn.name} will be resized"
          r.redirect kc
        end
      end
    end
  end
end
