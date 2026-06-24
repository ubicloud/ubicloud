# frozen_string_literal: true

class Prog::Test::KubernetesUpgrade < Prog::Test::KubernetesBase
  DATA_CANARY = "ubicloud-upgrade-canary"

  def self.assemble
    super(cluster_name: "kubernetes-test-upgrade", worker_node_count: 1)
  end

  label :start
  label :destroy_kubernetes
  label :finish
  label :failed

  label def wait_for_kubernetes_bootstrap
    hop_setup_statefulset if kubernetes_cluster.strand.label == "wait"
    nap 10
  end

  label def setup_statefulset
    apply_statefulset
    hop_wait_for_statefulset
  end

  label def wait_for_statefulset
    nap 5 unless kubernetes_cluster.client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").strip == "Running"

    write = NetSsh.command("echo :canary > /etc/data/upgrade-canary", canary: DATA_CANARY)
    kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- sh -c :write", write:)
    hop_trigger_upgrade
  end

  label def trigger_upgrade
    upgrade_candidate = kubernetes_cluster.available_upgrade_version
    unless upgrade_candidate
      self.fail_message = "No upgrade candidate available"
      hop_destroy_kubernetes
    end

    kubernetes_cluster.update(version: upgrade_candidate)
    kubernetes_cluster.incr_upgrade
    nodepool.incr_upgrade

    Clog.emit("waiting for k8s cluster upgrade to #{upgrade_candidate}")
    hop_wait_for_upgrade
  end

  label def wait_for_upgrade
    nap 15 unless kubernetes_cluster.display_state == "running"

    # kubectl reports the control-plane node as well as the workers, so compare
    # against the cluster's full node count rather than just the worker count.
    nodes = JSON.parse(kubernetes_cluster.client.kubectl("get nodes -o json"))["items"]
    unless nodes.size == kubernetes_cluster.all_nodes.count && nodes.all? { |n| n.dig("status", "nodeInfo", "kubeletVersion").start_with?("#{kubernetes_cluster.version}.") }
      self.fail_message = "Not all #{nodes.size} nodes upgraded to #{kubernetes_cluster.version}:\n#{kubernetes_cluster.client.kubectl("get nodes")}"
      hop_destroy_kubernetes
    end

    hop_verify_data_after_upgrade
  end

  label def verify_data_after_upgrade
    nap 5 unless pod_status == "Running"

    read = NetSsh.command("cat /etc/data/upgrade-canary")
    canary = kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- sh -c :read", read:).strip
    if canary != DATA_CANARY
      self.fail_message = "data did not survive upgrade, expected: #{DATA_CANARY}, got: #{canary}"
    end
    hop_destroy_kubernetes
  end
end
