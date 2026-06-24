# frozen_string_literal: true

class Prog::Test::Kubernetes < Prog::Test::KubernetesBase
  MIGRATION_TRIES = 1
  frame_accessor :read_hashes, :normal_pod_restart_test_node,
    :rsync_retry_source_node, :chained_migration_source_node, :drain_test_node_name, :reboot_node_id,
    :nat_rules_before_reboot, :pod_access_rules_before_reboot, :migration_number,
    :cert_expire_at_before_renew

  def self.assemble
    st = super(cluster_name: "kubernetes-test-standard", worker_node_count: 3)
    st.update(stack: [st.stack.first.merge("migration_number" => 0)])
    st
  end

  label :start
  label :destroy_kubernetes
  label :finish
  label :failed

  label def wait_for_kubernetes_bootstrap
    hop_trigger_renew_certs if kubernetes_cluster.strand.label == "wait"
    nap 10
  end

  label def trigger_renew_certs
    cp_node = kubernetes_cluster.nodes.first
    self.cert_expire_at_before_renew = cp_node.cert_expire_at.to_s
    cp_node.incr_renew_certs
    hop_wait_for_renew_certs
  end

  label def wait_for_renew_certs
    cp_node = kubernetes_cluster.nodes.first
    nap 10 unless cp_node.strand.label == "wait" && cp_node.state == "active" && !cp_node.renew_certs_set?
    nap 10 unless cp_node.cert_expire_at > Time.parse(cert_expire_at_before_renew)
    hop_test_nodes
  end

  label def test_nodes
    begin
      nodes_output = kubernetes_cluster.client.kubectl("get nodes")
    rescue RuntimeError => ex
      self.fail_message = "Failed to run test kubectl command: #{ex.message}"
      hop_destroy_kubernetes
    end
    missing_nodes = []
    kubernetes_cluster.all_nodes.each { |node|
      missing_nodes.append(node.name) unless nodes_output.include?(node.name)
    }
    if missing_nodes.any?
      self.fail_message = "node #{missing_nodes.join(", ")} not found in cluster"
      hop_destroy_kubernetes
    end
    hop_test_csi
  end

  label def test_csi
    apply_statefulset
    hop_wait_for_statefulset
  end

  label def wait_for_statefulset
    pod_status = kubernetes_cluster.client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").strip
    nap 5 unless pod_status == "Running"
    hop_test_lsblk
  end

  label def test_lsblk
    begin
      verify_mount
    rescue => e
      self.fail_message = e.message
      hop_destroy_kubernetes
    end
    hop_test_data_write
  end

  label def test_data_write
    (1..3).each do |i|
      unit_name = "csi_data_write_#{i}"
      kubernetes_cluster.sshable.d_run(
        unit_name,
        "bash", "-c",
        "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf exec -t ubuntu-statefulset-0 -- sh -c \"head -c 300M /dev/urandom | tee /etc/data/random-data-#{i} | sha256sum | awk '{print \\$1}'\" > /dev/shm/#{unit_name}.hash",
      )
    end
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
    hop_verify_data_write
  end

  label def verify_data_write
    read_hashes = {}
    (1..3).each do |i|
      file = "random-data-#{i}"
      unit_name = "csi_data_write_#{i}"
      hash_path = "/dev/shm/#{unit_name}.hash"
      write_hash = kubernetes_cluster.sshable.cmd("cat :hash_path", hash_path:).strip
      command = NetSsh.command("sha256sum /etc/data/:file | awk '{print $1}'", file:)
      read_hash = kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- sh -c :command", command:).strip
      kubernetes_cluster.sshable.d_clean(unit_name)
      if write_hash != read_hash
        self.fail_message = "wrong read hash for #{file}, expected: #{write_hash}, got: #{read_hash}"
        hop_destroy_kubernetes
      end
      read_hashes[file] = read_hash
    end
    self.read_hashes = read_hashes
    hop_test_pod_data_migration
  end

  label def test_pod_data_migration
    client = kubernetes_cluster.client
    pod_node = client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    client.kubectl("cordon :pod_node", pod_node:)
    # we need to uncordon other nodes each time so we won't run out of nodes accepting pods
    nodepool.nodes.reject { it.name == pod_node }.each {
      client.kubectl("uncordon :name", name: it.name)
    }
    client.kubectl("delete pod ubuntu-statefulset-0 --wait=false")
    hop_verify_data_after_migration
  end

  label def verify_data_after_migration
    nap 5 unless pod_status == "Running"
    verify_data_hashes("migration")
    hop_test_normal_pod_restart if migration_number == MIGRATION_TRIES
    self.migration_number += 1
    hop_test_pod_data_migration
  end

  label def test_normal_pod_restart
    client = kubernetes_cluster.client
    pod_node = client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    self.normal_pod_restart_test_node = pod_node
    client.kubectl("delete pod ubuntu-statefulset-0 --wait=false")
    hop_verify_normal_pod_restart
  end

  label def verify_normal_pod_restart
    nap 5 unless pod_status == "Running"
    pod_node = kubernetes_cluster.client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    expected_pod_node = normal_pod_restart_test_node
    if pod_node != expected_pod_node
      self.fail_message = "unexpected pod node change after restart, expected: #{expected_pod_node}, got: #{pod_node}"
      hop_destroy_kubernetes
    end

    begin
      verify_mount
    rescue => e
      self.fail_message = e.message
      hop_destroy_kubernetes
    end
    hop_test_rsync_retry
  end

  label def test_rsync_retry
    client = kubernetes_cluster.client
    nodepool.nodes.each { client.kubectl("uncordon :name", name: it.name) }
    pod_node_name = client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    client.kubectl("cordon :pod_node_name", pod_node_name:)
    client.kubectl("delete pod ubuntu-statefulset-0 --wait=false")
    self.rsync_retry_source_node = pod_node_name
    hop_kill_rsync_process
  end

  label def kill_rsync_process
    target_node_name = kubernetes_cluster.client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    nap 1 if target_node_name.empty?
    target_node = nodepool.nodes.find { it.name == target_node_name }
    nap 1 if target_node.vm.sshable.cmd("pgrep rsync || true").strip.empty?
    target_node.vm.sshable.cmd("sudo pkill -9 rsync")
    hop_verify_rsync_retry
  end

  label def verify_rsync_retry
    nap 5 unless pod_status == "Running"
    verify_data_hashes("rsync retry")
    hop_test_chained_migration
  end

  label def test_chained_migration
    client = kubernetes_cluster.client
    nodepool.nodes.each { client.kubectl("uncordon :name", name: it.name) }
    pod_node_name = client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    client.kubectl("cordon :pod_node_name", pod_node_name:)
    client.kubectl("delete pod ubuntu-statefulset-0 --wait=false")
    self.chained_migration_source_node = pod_node_name
    hop_cordon_chained_target
  end

  label def cordon_chained_target
    target_node_name = kubernetes_cluster.client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    nap 1 if target_node_name.empty?
    target_node = nodepool.nodes.find { it.name == target_node_name }
    # Wait for rsync to start so we know the first migration is in progress
    # before we cordon the target and force the chain to the third node
    nap 1 if target_node.vm.sshable.cmd("pgrep rsync || true").strip.empty?
    kubernetes_cluster.client.kubectl("cordon :name", name: target_node.name)
    kubernetes_cluster.client.kubectl("delete pod ubuntu-statefulset-0 --wait=false")
    hop_verify_chained_migration
  end

  label def verify_chained_migration
    nap 5 unless pod_status == "Running"
    verify_data_hashes("chained migration")
    hop_test_node_not_deleted_during_copy
  end

  label def test_node_not_deleted_during_copy
    client = kubernetes_cluster.client
    nodepool.nodes.each {
      client.kubectl("uncordon :name", name: it.name)
    }

    pod_node_name = client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    self.drain_test_node_name = pod_node_name

    pod_node = nodepool.nodes.find { it.name == pod_node_name }
    pod_node.incr_retire

    hop_verify_node_not_deleted_during_copy
  end

  label def verify_node_not_deleted_during_copy
    drain_node_name = drain_test_node_name
    drain_node = kubernetes_cluster.all_nodes.detect { it.name == drain_node_name }

    # Node record destroyed means the nexus completed the full retire flow
    hop_verify_data_after_drain unless drain_node

    if drain_node.pending_pvs.any?
      begin
        kubernetes_cluster.client.kubectl("get node :drain_node_name", drain_node_name:)
      rescue => e
        self.fail_message = "Node #{drain_node_name} was removed while CSI data copy was still in progress: #{e.message}"
        hop_destroy_kubernetes
      end
    end

    nap 15
  end

  label def verify_data_after_drain
    nap 5 unless pod_status == "Running"
    verify_data_hashes("node drain")
    hop_test_reboot_nftables
  end

  label def test_reboot_nftables
    node = nodepool.nodes.first
    nat_rules = node.vm.sshable.cmd("sudo nft list chain ip nat postrouting")
    pod_access_rules = node.vm.sshable.cmd("sudo nft list chain ip6 pod_access ingress_egress_control")

    self.reboot_node_id = node.id
    self.nat_rules_before_reboot = nat_rules
    self.pod_access_rules_before_reboot = pod_access_rules

    begin
      node.vm.sshable.cmd("sudo systemctl reboot")
    rescue
      # SSH connection drops during reboot
      nil
    end
    hop_verify_reboot_nftables
  end

  label def verify_reboot_nftables
    reboot_node = nodepool.nodes.find { |n| n.id == reboot_node_id }
    nap 5 unless vm_ready?(reboot_node.vm)
    nat_rules = reboot_node.vm.sshable.cmd("sudo nft list chain ip nat postrouting")
    pod_access_rules = reboot_node.vm.sshable.cmd("sudo nft list chain ip6 pod_access ingress_egress_control")
    if nat_rules != nat_rules_before_reboot
      self.fail_message = "ip nat rules changed after reboot"
      hop_destroy_kubernetes
    end
    if pod_access_rules != pod_access_rules_before_reboot
      self.fail_message = "ip6 pod_access rules changed after reboot"
    end
    hop_destroy_kubernetes
  end

  def vm_ready?(vm)
    return false unless vm

    vm.sshable.cmd("uptime")
    true
  rescue
    false
  end

  def verify_data_hashes(context)
    expected_hashes = read_hashes
    expected_hashes.each do |file, expected_hash|
      command = NetSsh.command("sha256sum /etc/data/:file | awk '{print $1}'", file:)
      new_hash = kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- sh -c :command", command:).strip
      if new_hash != expected_hash
        self.fail_message = "data hash changed after #{context} for #{file}, expected: #{expected_hash}, got: #{new_hash}"
        hop_destroy_kubernetes
      end
    end
  end
end
