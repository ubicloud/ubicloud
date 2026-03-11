# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodeNexus < Prog::Base
  subject_is :kubernetes_node

  def self.assemble(project_id, sshable_unix_user:, name:, location_id:, size:, storage_volumes:, boot_image:, private_subnet_id:, enable_ip4:, kubernetes_cluster_id:, kubernetes_nodepool_id: nil)
    DB.transaction do
      id = KubernetesNode.generate_uuid
      cluster = KubernetesCluster[kubernetes_cluster_id]

      exclude_host_ids = if kubernetes_nodepool_id || Config.allow_unspread_servers
        []
      else
        cluster.cp_vms_dataset
          .exclude(vm_host_id: nil)
          .unordered
          .distinct
          .select_map(:vm_host_id)
      end

      vm = Prog::Vm::Nexus.assemble_with_sshable(project_id, sshable_unix_user:, name:, location_id:,
        size:, storage_volumes:, boot_image:, private_subnet_id:, enable_ip4:,
        allow_private_subnet_in_other_project: true,
        exclude_host_ids:).subject

      KubernetesNode.create_with_id(id, vm_id: vm.id, kubernetes_cluster_id:, kubernetes_nodepool_id:)

      internal_firewall = kubernetes_nodepool_id ? cluster.internal_worker_vm_firewall : cluster.internal_cp_vm_firewall
      vm.add_vm_firewall(internal_firewall)

      Strand.create_with_id(id, prog: "Kubernetes::KubernetesNodeNexus", label: "start")
    end
  end

  def cluster
    kubernetes_node.kubernetes_cluster
  end

  def nodepool
    kubernetes_node.kubernetes_nodepool
  end

  label def start
    hop_wait
  end

  label def wait
    when_checkup_set? do
      hop_unavailable
    end

    when_retire_set? do
      hop_retire
    end
    nap 6 * 60 * 60
  end

  label def unavailable
    if available?
      decr_checkup
      hop_wait
    end

    Clog.emit("KubernetesNode is unavailable due to mesh connectivity issues", {kubernetes_node_unavailable: {ubid: kubernetes_node.ubid, name: kubernetes_node.name}})
    register_deadline("wait", 15 * 60)
    nap 15
  end

  label def retire
    kubernetes_node.update(state: "draining")
    hop_drain
  end

  # TLA \* Models KubernetesNodeNexus: retire -> drain transition.
  # TLA \* The node transitions to Draining state (kubectl drain --ignore-daemonsets).
  # TLA StartDrain(n) ==
  # TLA     /\ n \in Nodes
  # TLA     /\ nodeState[n] = NodeActive
  # TLA     /\ nodeSchedulable[n] = FALSE
  # TLA     /\ nodeState' = [nodeState EXCEPT ![n] = NodeDraining]
  # TLA     /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
  # TLA                    targetMounts, nodeSchedulable, migState, migTarget,
  # TLA                    migSource, migRetryCount, migReclaimRetain, paged>>
  # TLA
  # TLA \* Models KubernetesNodeNexus: drain -> wait_for_copy transition.
  # TLA \* Drain has completed: kubectl drain evicts all pods on this node, which
  # TLA \* triggers NodeUnpublish + NodeUnstage for every volume.  Drain only
  # TLA \* completes when all pods are evicted, so no volumes can have active
  # TLA \* staging/target mounts on this node.
  # TLA CompleteDrain(n) ==
  # TLA     /\ n \in Nodes
  # TLA     /\ nodeState[n] = NodeDraining
  # TLA     /\ ¬∃ v \in Volumes : ⟨v, n⟩ \in stagingMounts \/ ⟨v, n⟩ \in targetMounts
  # TLA     /\ nodeState' = [nodeState EXCEPT ![n] = NodeWaitForCopy]
  # TLA     /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
  # TLA                    targetMounts, nodeSchedulable, migState, migTarget,
  # TLA                    migSource, migRetryCount, migReclaimRetain, paged>>
  label def drain
    unit_name = "drain_node_#{kubernetes_node.name}"
    sshable = cluster.sshable
    case sshable.d_check(unit_name)
    # TLA \* CompleteDrain: d_check == "Succeeded" → hop_wait_for_copy
    when "Succeeded"
      hop_wait_for_copy
    # TLA \* StartDrain: d_check == "NotStarted" → d_run kubectl drain
    when "NotStarted"
      sshable.d_run(unit_name, "sudo", "kubectl", "--kubeconfig=/etc/kubernetes/admin.conf",
        "drain", kubernetes_node.name, "--ignore-daemonsets", "--delete-emptydir-data")
      nap 10
    when "InProgress"
      nap 10
    when "Failed"
      sshable.d_restart(unit_name)
      nap 10
    else
      register_deadline("destroy", 0)
      nap 3 * 60 * 60
    end
  end

  # TLA \* Models KubernetesNodeNexus: wait_for_copy -> remove_node_from_cluster.
  # TLA \* Only proceeds when pending_pvs is empty (no more volumes migrating from this node).
  # TLA RemoveNode(n) ==
  # TLA     /\ n \in Nodes
  # TLA     /\ nodeState[n] = NodeWaitForCopy
  # TLA     /\ PendingPVs(n) = {}
  # TLA     /\ nodeState' = [nodeState EXCEPT ![n] = NodeRemoved]
  # TLA     /\ UNCHANGED <<phase, owner, backingFiles, loopDevices, stagingMounts,
  # TLA                    targetMounts, nodeSchedulable, migState, migTarget,
  # TLA                    migSource, migRetryCount, migReclaimRetain, paged>>
  label def wait_for_copy
    # TLA \* PendingPVs(n) = {} → hop_remove_node_from_cluster
    pending = kubernetes_node.pending_pvs
    if pending.any?
      pv_names = pending.map { |pv| pv.dig("metadata", "name") }
      Clog.emit("Waiting for CSI data copy to complete", {pending_pvs: {ubid: kubernetes_node.ubid, name: kubernetes_node.name, pvs: pv_names}})
      nap 15
    end
    hop_remove_node_from_cluster
  end

  label def remove_node_from_cluster
    # kubeadm reset is necessary for etcd member removal, deleting the node itself
    # won't remove the node from the etcd cluster, hurting the etcd cluster health
    kubernetes_node.sshable.cmd("sudo kubeadm reset --force")

    if nodepool
      cluster.services_lb.detach_vm(kubernetes_node.vm)
    else
      cluster.api_server_lb.detach_vm(kubernetes_node.vm)
    end

    cluster.client.delete_node(kubernetes_node.name)

    hop_destroy
  end

  label def destroy
    kubernetes_node.vm.incr_destroy
    kubernetes_node.destroy
    cluster.incr_sync_internal_dns_config
    cluster.incr_sync_worker_mesh
    pop "kubernetes node is deleted"
  end

  def available?
    kubernetes_node.available?
  end
end
