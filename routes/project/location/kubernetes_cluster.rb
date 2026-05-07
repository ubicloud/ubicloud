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

      r.get true do
        authorize("KubernetesCluster:view", kc)
        if api?
          Serializers::KubernetesCluster.serialize(kc, {detailed: true})
        else
          r.redirect kc, "/overview"
        end
      end

      r.delete true do
        authorize("KubernetesCluster:delete", kc)
        DB.transaction do
          kc.incr_destroy
          audit_log(kc, "destroy")
        end

        if web?
          flash["notice"] = "Kubernetes cluster scheduled for deletion."
          r.redirect @project, "/kubernetes-cluster"
        else
          204
        end
      end

      r.rename kc, perm: "KubernetesCluster:edit", serializer: Serializers::KubernetesCluster, template_prefix: "kubernetes-cluster"

      r.show_object(kc, actions: %w[overview nodepools networking settings], perm: "KubernetesCluster:view", template: "kubernetes-cluster/show")

      r.post "connect-postgres", :ubid_uuid do |pg_id|
        authorize("KubernetesCluster:view", kc)
        handle_validation_failure("kubernetes-cluster/show") { @page = "networking" }

        pg = @project.postgres_resources_dataset.first(id: pg_id)
        check_found_object(pg)
        authorize("Postgres:view", pg)

        kc_ps = kc.private_subnet
        pg_ps = pg.private_subnet

        authorize("PrivateSubnet:connect", kc_ps.id)

        pg_ps.firewalls.each do |fw|
          authorize("Firewall:edit", fw.id)
        end

        cidr = kc_ps.net4.to_s

        DB.transaction do
          kc_ps.connect_subnet(pg_ps)
          audit_log(kc_ps, "connect", pg_ps)

          pg_ps.firewalls.each do |fw|
            fwr1 = fw.insert_firewall_rule(cidr, Sequel.pg_range(5432..5432))
            audit_log(fwr1, "create", fw)
            fwr2 = fw.insert_firewall_rule(cidr, Sequel.pg_range(6432..6432))
            audit_log(fwr2, "create", fw)
          end
        end

        flash["notice"] = "Connecting to #{pg.name}. Firewall rules will be updated in a few seconds."
        r.redirect kc, "/networking"
      end

      r.get "kubeconfig" do
        authorize("KubernetesCluster:edit", kc)
        handle_validation_failure("kubernetes-cluster/show") { @page = "overview" }

        unless kc.kubeconfig
          raise CloverError.new(503, "ServiceUnavailable", "Temporary error downloading kubeconfig.yaml. Please try again.")
        end

        response.attachment "#{kc.name}-kubeconfig.yaml"
        kc.kubeconfig
      end

      r.post "nodepool" do
        handle_validation_failure("kubernetes-cluster/show") { @page = "nodepools" }
        kubernetes_nodepool_post(typecast_params.nonempty_str!("name"))
      end

      r.on "nodepool", KUBERNETES_NODEPOOL_NAME_OR_UBID do |kn_name, kn_id|
        filter = if kn_name
          {Sequel[:kubernetes_nodepool][:name] => kn_name}
        else
          {Sequel[:kubernetes_nodepool][:id] => kn_id}
        end

        filter[:kubernetes_cluster_id] = kc.id
        kn = @kn = kc.nodepools_dataset.first(filter)

        check_found_object(kn)

        r.rename kn, perm: "KubernetesCluster:edit", serializer: Serializers::KubernetesNodepool, template_prefix: "kubernetes-cluster/nodepool"

        r.show_object(kn, actions: %w[overview nodes settings], perm: "KubernetesCluster:view", template: "kubernetes-cluster/nodepool/show")

        r.post "resize" do
          authorize("KubernetesCluster:edit", kc.id)
          handle_validation_failure("kubernetes-cluster/nodepool/show") { @page = "settings" }

          unless kn.idle?
            fail_kubernetes_unprocessable("Nodepool is not ready to be resized")
          end

          unless kc.idle?
            fail_kubernetes_unprocessable("Cluster is not ready to resize a nodepool")
          end

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
            audit_log(kn, "update", [kc])
          end

          if api?
            Serializers::KubernetesNodepool.serialize(kn, {detailed: true})
          else
            flash["notice"] = "#{kc.name} node pool #{kn.name} will be resized"
            r.redirect kn, "/settings"
          end
        end

        r.post "upgrade" do
          authorize("KubernetesCluster:edit", kc.id)
          handle_validation_failure("kubernetes-cluster/nodepool/show") { @page = "settings" }

          unless kn.ready_for_upgrade?
            fail_kubernetes_unprocessable("Nodepool is not ready to be upgraded")
          end

          upgrade_candidate = kn.available_upgrade_version
          DB.transaction do
            kn.update(version: upgrade_candidate)
            kn.incr_upgrade_requested
            kc.incr_upgrade_nodepools
            audit_log(kn, "upgrade", [kc])
          end

          if api?
            Serializers::KubernetesNodepool.serialize(kn, {detailed: true})
          else
            flash["notice"] = "#{kc.name} node pool #{kn.name} will be upgraded to #{upgrade_candidate}"
            r.redirect kn, "/settings"
          end
        end

        r.delete true do
          authorize("KubernetesCluster:edit", kc.id)

          DB.transaction do
            kc.lock!

            if !kn.destroying? && kc.nodepools(eager: [:strand, :semaphores]).count { !it.destroying? } == 1
              fail_kubernetes_unprocessable("You cannot delete the last nodepool of a cluster")
            end

            kn.incr_destroy
            audit_log(kn, "destroy", [kc])
          end

          if web?
            flash["notice"] = "#{kn.name} nodepool is scheduled for deletion"
            r.redirect kc, "/nodepools"
          else
            204
          end
        end
      end

      r.post "node", :object_name, "retire" do |node_name|
        node = kc.nodepools_dataset.eager(nodes: :vm).all.flat_map(&:nodes).find { it.name == node_name }

        check_found_object(node)

        authorize("KubernetesCluster:edit", kc.id)

        handle_validation_failure("kubernetes-cluster/nodepool/show") { @page = "nodes" }

        np = nil
        DB.transaction do
          np = @kn = node.kubernetes_nodepool(&:for_update)

          if node.retire_set?
            fail_kubernetes_unprocessable("Node #{node.name} is already being retired")
          end

          if np.node_count <= 1
            fail_kubernetes_unprocessable("You cannot retire the last node of a nodepool")
          end

          node.incr_retire
          np.this.update(node_count: Sequel[:node_count] - 1)
          audit_log(node, "retire", [kc, np])
        end

        if api?
          Serializers::KubernetesNodepool.serialize(np.reload, {detailed: true})
        else
          flash["notice"] = "Node #{node.name} is scheduled to be retired"
          r.redirect np, "/nodes"
        end
      end

      r.post "upgrade" do
        authorize("KubernetesCluster:edit", kc)
        unless kc.nodepools_within_version_skew?
          fail_kubernetes_unprocessable("All nodepools must be upgraded to within two minor versions of the cluster first")
        end
        unless kc.ready_for_upgrade?
          fail_kubernetes_unprocessable("Cluster is not ready to be upgraded")
        end

        upgrade_candidate = kc.available_upgrade_version
        DB.transaction do
          kc.update(version: upgrade_candidate)
          kc.incr_upgrade
          audit_log(kc, "upgrade")
        end

        if api?
          Serializers::KubernetesCluster.serialize(kc, {detailed: true})
        else
          flash["notice"] = "#{kc.name} will be upgraded to #{upgrade_candidate}"
          r.redirect kc
        end
      end
    end
  end
end
