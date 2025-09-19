# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::Kubernetes < Prog::Test::Base
  semaphore :destroy

  MIGRATION_TRIES = 3

  def self.assemble
    kubernetes_test_project = Project.create(name: "Kubernetes-Test-Project", feature_flags: {"install_csi" => true})
    kubernetes_service_project = Project.create_with_id(Config.kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources")

    Strand.create(
      prog: "Test::Kubernetes",
      label: "start",
      stack: [{
        "kubernetes_service_project_id" => kubernetes_service_project.id,
        "kubernetes_test_project_id" => kubernetes_test_project.id,
        "migration_number" => 0
      }]
    )
  end

  label def start
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "kubernetes-test-standard",
      project_id: frame["kubernetes_test_project_id"],
      location_id: Location::HETZNER_FSN1_ID,
      version: Option.kubernetes_versions.first,
      cp_node_count: 1
    ).subject
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
      name: "kubernetes-test-standard-nodepool",
      node_count: 2,
      kubernetes_cluster_id: kc.id,
      target_node_size: "standard-2"
    )

    update_stack({"kubernetes_cluster_id" => kc.id})
    hop_update_loadbalancer_hostname
  end

  label def update_loadbalancer_hostname
    nap 5 unless kubernetes_cluster.api_server_lb
    kubernetes_cluster.api_server_lb.update(custom_hostname: "k8s-e2e-test.ubicloud.test")
    hop_update_all_nodes_hosts_entries
  end

  label def update_all_nodes_hosts_entries
    expected_node_count = kubernetes_cluster.cp_node_count + nodepool.node_count
    current_nodes = kubernetes_cluster.nodes + nodepool.nodes
    current_node_count = current_nodes.count

    current_nodes.each { |node|
      unless node_host_entries_set?(node.name)
        nap 5 unless vm_ready?(node.vm)
        ensure_hosts_entry(node.sshable, kubernetes_cluster.api_server_lb.hostname)
        set_node_entries_status(node.name)
      end
    }

    hop_wait_for_kubernetes_bootstrap if current_node_count == expected_node_count
    nap 10
  end

  label def wait_for_kubernetes_bootstrap
    hop_test_nodes if kubernetes_cluster.strand.label == "wait"
    nap 10
  end

  label def test_nodes
    begin
      nodes_output = kubernetes_cluster.client.kubectl("get nodes")
    rescue RuntimeError => ex
      update_stack({"fail_message" => "Failed to run test kubectl command: #{ex.message}"})
      hop_destroy_kubernetes
    end
    missing_nodes = []
    kubernetes_cluster.all_nodes.each { |node|
      missing_nodes.append(node.name) unless nodes_output.include?(node.name)
    }
    if missing_nodes.any?
      update_stack({"fail_message" => "node #{missing_nodes.join(", ")} not found in cluster"})
      hop_destroy_kubernetes
    end
    hop_test_csi
  end

  label def test_csi
    sts = <<STS
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ubuntu-statefulset
spec:
  serviceName: ubuntu
  replicas: 1
  selector:
    matchLabels: { app: ubuntu }
  template:
    metadata:
      labels: { app: ubuntu }
    spec:
      containers:
      - name: ubuntu
        image: ubuntu:24.04
        command: ["/bin/sh", "-c", "sleep infinity"]
        volumeMounts:
        - { name: data-volume, mountPath: /etc/data }
  volumeClaimTemplates:
  - metadata:
      name: data-volume
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests: { storage: 1Gi }
      storageClassName: ubicloud-standard
STS
    kubernetes_cluster.sshable.cmd("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -", stdin: sts)
    hop_wait_for_statefulset
  end

  label def wait_for_statefulset
    pod_status = kubernetes_cluster.client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").strip
    nap 5 unless pod_status == "Running"
    hop_test_lsblk
  end

  label def test_lsblk
    lsblk_output = kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- lsblk")
    lines = lsblk_output.split("\n")[1..]
    data_mount = lines.find { |line| line.include?("/etc/data") }
    if data_mount
      cols = data_mount.split
      device_name = cols[0]  # e.g. "loop3"
      size = cols[3]         # e.g. "1G"
      mountpoint = cols[6]   # e.g. "/etc/data"

      if device_name.start_with?("loop") && size == "1G" && mountpoint == "/etc/data"
        hop_test_data_write
      else
        update_stack({"fail_message" => "/etc/data is mounted incorrectly: #{data_mount}"})
        hop_destroy_kubernetes
      end
    else
      update_stack({"fail_message" => "No /etc/data mount found in lsblk output"})
      hop_destroy_kubernetes
    end
  end

  label def test_data_write
    write_hash = kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- sh -c \"head -c 200M /dev/urandom | tee /etc/data/random-data | sha256sum | awk '{print \\$1}'\"").strip
    read_hash = kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- sh -c \"sha256sum /etc/data/random-data | awk '{print \\$1}'\"").strip
    if write_hash != read_hash
      update_stack({"fail_message" => "wrong read hash, expected: #{write_hash}, got: #{read_hash}"})
      hop_destroy_kubernetes
    end
    update_stack({"read_hash" => read_hash})
    hop_test_pod_data_migration
  end

  label def test_pod_data_migration
    client = kubernetes_cluster.client
    pod_node = client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").strip
    client.kubectl("cordon #{pod_node}")
    # we need to uncordon other nodes each time so we won't run out of nodes accepting pods
    nodepool.nodes.reject { it.name == pod_node }.each { |node|
      client.kubectl("uncordon #{node.name}")
    }
    client.kubectl("delete pod ubuntu-statefulset-0 --wait=false")
    hop_verify_data_after_migration
  end

  label def verify_data_after_migration
    pod_status = kubernetes_cluster.client.kubectl("get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").strip
    nap 5 unless pod_status == "Running"
    new_hash = kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- sh -c \"sha256sum /etc/data/random-data | awk '{print \\$1}'\"").strip
    expected_hash = strand.stack.first["read_hash"]
    if new_hash != expected_hash
      update_stack({"fail_message" => "data hash changed after migration, expected: #{expected_hash}, got: #{new_hash}"})
      hop_destroy_kubernetes
    end
    hop_destroy_kubernetes if migration_number == MIGRATION_TRIES
    increment_migration_number
    hop_test_pod_data_migration
  end

  label def destroy_kubernetes
    kubernetes_cluster.incr_destroy
    hop_destroy
  end

  label def destroy
    nap 5 if kubernetes_cluster
    kubernetes_test_project.destroy

    fail_test(frame["fail_message"]) if frame["fail_message"]

    pop "Kubernetes tests are finished!"
  end

  label def failed
    nap 15
  end

  def ensure_hosts_entry(sshable, api_hostname)
    host_line = "#{kubernetes_cluster.sshable.host} #{api_hostname}"
    output = sshable.cmd("cat /etc/hosts")
    unless output.include?(host_line)
      sshable.cmd("echo #{host_line.shellescape} | sudo tee -a /etc/hosts > /dev/null")
    end
  end

  def vm_ready?(vm)
    return false unless vm
    vm.sshable.cmd("uptime")
    true
  rescue
    false
  end

  def kubernetes_test_project
    @kubernetes_test_project ||= Project.with_pk(frame["kubernetes_test_project_id"])
  end

  def kubernetes_cluster
    @kubernetes_cluster ||= KubernetesCluster.with_pk(frame["kubernetes_cluster_id"])
  end

  def nodepool
    kubernetes_cluster.nodepools.first
  end

  def node_host_entries_set?(node_name)
    strand.stack.first.dig("nodes_status", node_name) == true
  end

  def set_node_entries_status(node_name)
    frame = strand.stack.first
    frame["nodes_status"] ||= {}
    frame["nodes_status"][node_name] = true
    update_stack(frame)
  end

  def migration_number
    strand.stack.first["migration_number"]
  end

  def increment_migration_number
    update_stack({"migration_number" => migration_number + 1})
  end
end
