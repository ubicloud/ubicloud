# frozen_string_literal: true

class Prog::Test::KubernetesBase < Prog::Test::Base
  STATEFULSET_YAML = <<~STS
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
            requests: { storage: 5Gi }
          storageClassName: ubicloud-standard
  STS

  frame_reader :kubernetes_service_project_id, :kubernetes_test_project_id, :cluster_name, :worker_node_count
  frame_accessor :fail_message, :kubernetes_cluster_id

  def self.assemble(cluster_name:, worker_node_count:)
    kubernetes_test_project = Project.create(name: "Kubernetes-Test-Project")
    kubernetes_service_project = Project[Config.kubernetes_service_project_id] ||
      Project.create_with_id(Config.kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources")
    Strand.create(
      prog: name.delete_prefix("Prog::"),
      label: "start",
      stack: [{
        "kubernetes_service_project_id" => kubernetes_service_project.id,
        "kubernetes_test_project_id" => kubernetes_test_project.id,
        "cluster_name" => cluster_name,
        "worker_node_count" => worker_node_count,
      }],
    )
  end

  def start
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: cluster_name,
      project_id: kubernetes_test_project_id,
      location_id: Location::HETZNER_FSN1_ID,
      version: Option.selectable_kubernetes_versions[1],
      cp_node_count: 1,
    ).subject
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
      name: "#{cluster_name}-nodepool",
      node_count: worker_node_count,
      kubernetes_cluster_id: kc.id,
      target_node_size: "standard-2",
    )

    self.kubernetes_cluster_id = kc.id
    hop_wait_for_kubernetes_bootstrap
  end

  def destroy_kubernetes
    kubernetes_cluster.incr_destroy
    hop_finish
  end

  def finish
    nap 5 if kubernetes_cluster
    kubernetes_test_project.destroy

    fail_test(fail_message) if fail_message

    pop "#{self.class.name.delete_prefix("Prog::Test::")} tests are finished!"
  end

  def failed
    nap 15
  end

  def kubernetes_test_project
    @kubernetes_test_project ||= Project.with_pk(kubernetes_test_project_id)
  end

  def kubernetes_cluster
    @kubernetes_cluster ||= KubernetesCluster.with_pk(kubernetes_cluster_id)
  end

  def nodepool
    kubernetes_cluster.nodepools.first
  end

  def apply_statefulset
    kubernetes_cluster.sshable.cmd("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -", stdin: STATEFULSET_YAML)
  end

  def verify_mount
    lsblk_output = kubernetes_cluster.client.kubectl("exec -t ubuntu-statefulset-0 -- lsblk")
    lines = lsblk_output.split("\n")[1..]
    data_mount = lines.find { |line| line.include?("/etc/data") }
    if data_mount
      cols = data_mount.split
      device_name = cols[0]  # e.g. "loop3"
      size = cols[3]         # e.g. "1G"
      mountpoint = cols[6]   # e.g. "/etc/data"

      if device_name.start_with?("loop") && size == "5G" && mountpoint == "/etc/data"
        # no op
      else
        raise "/etc/data is mounted incorrectly: #{data_mount}"
      end
    else
      raise "No /etc/data mount found in lsblk output"
    end
  end

  # we are not using jsonpath for extracting the status because even though a pod is termination, its phase
  # from API Server's point of view is Running, in order to detect that using jsonpath, we needed to check for
  # deletion timestamp, all conditions in status and .status.phase.
  # to keep the query simple, we let the kubectl do the processing and observe the system from the eyes of a
  # customer. This also keeps the logic simpler
  def pod_status
    status = kubernetes_cluster.client.kubectl("get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").strip
    if status != "Running"
      client = kubernetes_cluster.client
      Clog.emit("pod not running", {
        pod_status: status,
        events: begin; client.kubectl("get events --field-selector involvedObject.name=ubuntu-statefulset-0 --sort-by=.lastTimestamp"); rescue => e; e.message; end,
        pv_pvc: begin; client.kubectl("get pv,pvc"); rescue => e; e.message; end,
      })
    end
    status
  end
end
