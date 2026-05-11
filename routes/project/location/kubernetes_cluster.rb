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

      r.show_object(kc, actions: %w[overview nodes networking settings], perm: "KubernetesCluster:view", template: "kubernetes-cluster/show")

      r.post web?, "connect-postgres", :ubid_uuid, :ubid_uuid do |pg_id, fw_id|
        authorize("KubernetesCluster:view", kc)
        handle_validation_failure("kubernetes-cluster/show") { @page = "networking" }

        pg = @project.postgres_resources_dataset.first(location_id: kc.location_id, id: pg_id)
        check_found_object(pg)
        authorize("Postgres:view", pg)

        kc_ps = kc.private_subnet
        pg_ps = pg.private_subnet

        authorize("PrivateSubnet:connect", kc_ps.id)
        authorize("PrivateSubnet:connect", pg_ps.id)

        fw = pg_ps.firewalls_dataset.first(id: fw_id)
        if fw.private_subnets_dataset.count > 1
          flash["error"] = "Unable to connect to #{pg.name} as the requested firewall is used by other subnets."
          r.redirect kc, "/networking"
        end
        authorize("Firewall:edit", fw.id)

        cidrs = [kc_ps.net4.to_s, kc_ps.net6.to_s]
        ranges = [Sequel.pg_range(5432...5433), Sequel.pg_range(6432...6433)]

        fw_rules = fw.firewall_rules_dataset
          .where(cidr: cidrs, port_range: ranges)
          .select_map([:cidr, :port_range])
          .to_set do |cidr, port_range|
            [cidr.to_s, port_range.begin, port_range.end]
          end

        DB.transaction do
          kc_ps.connect_subnet(pg_ps)
          audit_log(kc_ps, "connect", pg_ps)

          fwrs = DB.ignore_duplicate_queries do
            ranges.flat_map do |range|
              cidrs.map do |cidr|
                unless fw_rules.include?([cidr, range.begin, range.end])
                  fw.insert_firewall_rule(cidr, range)
                end
              end
            end
          end
          fwrs.compact!
          if (fwr = fwrs.shift)
            audit_log(fwr, "create", fwrs << fw)
          end
        end

        flash["notice"] = "Connecting to #{pg.name}. Firewall rules will be updated in a few seconds."
        r.redirect kc, "/networking"
      end

      r.get "kubeconfig" do
        authorize("KubernetesCluster:edit", kc)
        handle_validation_failure("kubernetes-cluster/show") { @page = "overview" }

        # TODO: Avoid SSH connection from console to k8s cp nodes
        unless (kubeconfig = kc.kubeconfig(swallow_connection_exception: true))
          raise CloverError.new(503, "ServiceUnavailable", "Temporary error downloading kubeconfig.yaml. Please try again.")
        end

        response.attachment "#{kc.name}-kubeconfig.yaml"
        kubeconfig
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
