# frozen_string_literal: true

class Prog::Test::KubernetesUpgrade < Prog::Test::KubernetesBase
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

    write_data_files
    hop_wait_data_write
  end

  label def wait_data_write
    (1..3).each do |i|
      unit_name = "csi_data_write_#{i}"
      case kubernetes_cluster.sshable.d_check(unit_name)
      when "InProgress"
        nap 30
      when "Failed"
        self.fail_message = "daemonized write for random-data-#{i} failed"
        hop_destroy_kubernetes
      end
    end

    read_hashes = {}
    (1..3).each do |i|
      unit_name = "csi_data_write_#{i}"
      hash_path = "/dev/shm/#{unit_name}.hash"
      read_hashes["random-data-#{i}"] = kubernetes_cluster.sshable.cmd("cat :hash_path", hash_path:).strip
      kubernetes_cluster.sshable.d_clean(unit_name)
    end
    self.read_hashes = read_hashes
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

    verify_data_hashes("upgrade")
    hop_destroy_kubernetes
  end
end
