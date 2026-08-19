# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodeNexus < Prog::Base
  subject_is :kubernetes_node

  def self.assemble(project_id, sshable_unix_user:, name:, location_id:, size:, storage_volumes:, boot_image:, enable_ip4:, kubernetes_cluster_id:, kubernetes_nodepool_id: nil)
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
        size:, storage_volumes:, boot_image:, private_subnet_id: cluster.private_subnet_id, enable_ip4:,
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

    when_renew_certs_set? do
      hop_renew_certs
    end

    when_configure_metrics_set? do
      hop_configure_metrics
    end

    nap 6 * 60 * 60
  end

  label def configure_metrics
    register_deadline("wait", 30 * 60)
    decr_configure_metrics

    sshable = kubernetes_node.sshable
    metrics_dir = metrics_config[:metrics_dir]
    sshable.cmd("mkdir -p :metrics_dir", metrics_dir:)
    sshable.write_file("#{metrics_dir}/config.json", metrics_config.to_json, user: :current)
    sshable.write_file("/etc/systemd/system/kubernetes-metrics.service", metrics_service)
    sshable.write_file("/etc/systemd/system/kubernetes-metrics.timer", metrics_timer)

    sshable.cmd("sudo systemctl daemon-reload")
    sshable.cmd("sudo systemctl enable --now kubernetes-metrics.timer")

    hop_wait unless kubernetes_node.control_plane?
    hop_configure_prometheus
  end

  label def configure_prometheus
    encoded_token = cluster.client.kubectl("-n kube-system get secret prometheus-metrics -o jsonpath='{.data.token}' --ignore-not-found")
    nap 10 if encoded_token.empty?

    sshable = kubernetes_node.sshable
    sshable.write_file("/etc/prometheus/token", Base64.decode64(encoded_token))
    sshable.cmd("sudo chown prometheus:prometheus /etc/prometheus/token")
    sshable.cmd("sudo chmod 600 /etc/prometheus/token")
    sshable.write_file("/etc/prometheus/prometheus.yml", prometheus_config)
    sshable.write_file("/etc/prometheus/rules.yml", prometheus_rules)
    sshable.cmd("sudo systemctl enable --now prometheus")
    sshable.cmd("sudo systemctl reload prometheus")

    hop_wait
  end

  def prometheus_config
    <<CONFIG
global:
  scrape_interval: #{metrics_config[:interval]}

rule_files:
  - /etc/prometheus/rules.yml

scrape_configs:
- job_name: apiserver
  scheme: https
  tls_config:
    insecure_skip_verify: true
  bearer_token_file: /etc/prometheus/token
  static_configs:
  - targets: ['localhost:6443']
- job_name: scheduler
  scheme: https
  tls_config:
    insecure_skip_verify: true
  bearer_token_file: /etc/prometheus/token
  static_configs:
  - targets: ['localhost:10259']
CONFIG
  end

  def prometheus_rules
    <<RULES
groups:
- name: ubicloud
  interval: #{metrics_config[:interval]}
  rules:
  - record: ubicloud:apiserver_request:rate5m
    expr: sum by (code) (rate(apiserver_request_total[5m]))
  - record: ubicloud:apiserver_latency_seconds:p99
    expr: histogram_quantile(0.99, sum by (verb, le) (rate(apiserver_request_duration_seconds_bucket[5m])))
  - record: ubicloud:apiserver_latency_seconds:p50
    expr: histogram_quantile(0.50, sum by (verb, le) (rate(apiserver_request_duration_seconds_bucket[5m])))
  - record: ubicloud:apiserver_storage_objects:total
    expr: sum(apiserver_storage_objects)
RULES
  end

  def metrics_config
    @metrics_config ||= kubernetes_node.metrics_config
  end

  def metrics_service
    <<SERVICE
[Unit]
Description=Kubernetes Node Metrics Collection

[Service]
Type=oneshot
User=ubi
ExecStart=/home/ubi/common/bin/metrics-collector #{metrics_config[:metrics_dir]}
StandardOutput=journal
StandardError=journal
SERVICE
  end

  def metrics_timer
    <<TIMER
[Unit]
Description=Run Kubernetes Node Metrics Collection Periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=#{metrics_config[:interval]}
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER
  end

  label def renew_certs
    register_deadline("wait", 10 * 60)
    decr_renew_certs

    state = kubernetes_node.sshable.d_check("renew_certs")
    case state
    when "Succeeded"
      kubernetes_node.sshable.d_clean("renew_certs")
      kubernetes_node.update(state: "active")
      hop_wait
    when "NotStarted"
      kubernetes_node.update(state: "renewing_certs")
      kubernetes_node.sshable.d_run("renew_certs", "/home/ubi/kubernetes/bin/renew-certs")
      nap 30
    when "InProgress"
      nap 30
    else
      Clog.emit((state == "Failed") ? "renew_certs failed" : "got unknown state from daemonizer2 check: #{state}", {kubernetes_node: {ubid: kubernetes_node.ubid, name: kubernetes_node.name}})
      nap 30
    end
  end

  label def unavailable
    when_retire_set? do
      hop_retire
    end

    if available?
      decr_checkup
      hop_wait
    end

    Clog.emit("KubernetesNode is unavailable due to mesh connectivity issues", {kubernetes_node_unavailable: {ubid: kubernetes_node.ubid, name: kubernetes_node.name}})
    register_deadline("wait", 15 * 60)
    nap 15
  end

  label def retire
    register_deadline("destroy", 6 * 60 * 60)
    kubernetes_node.update(state: "draining")
    hop_retain_volumes
  end

  # Retain every PV pinned to this node before draining, driven from the control
  # plane so the data survives even when this node's own CSI pod is down.
  label def retain_volumes
    node_pvs.each do |pv|
      next unless pv.dig("status", "phase") == "Bound"
      next if pv.dig("spec", "persistentVolumeReclaimPolicy") == "Retain"
      cluster.client.retain_pv(pv.dig("metadata", "name"))
    end
    hop_drain
  end

  label def drain
    unit_name = "drain_node_#{kubernetes_node.name}"
    sshable = cluster.sshable
    case sshable.d_check(unit_name)
    when "Succeeded"
      hop_wait_for_detach
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

  label def wait_for_detach
    attachments = JSON.parse(cluster.client.kubectl("get volumeattachments -ojson"))["items"]
    node_attachments = attachments.select { |va|
      va.dig("spec", "nodeName") == kubernetes_node.name &&
        va.dig("spec", "attacher") == "csi.ubicloud.com"
    }
    if node_attachments.any?
      nap 5
    end
    hop_wait_for_copy
  end

  label def wait_for_copy
    # Block while any PV's data still lives on this node: Bound means migration
    # never started, Retain means the copy is still in flight.
    unmigrated = node_pvs.select do |pv|
      pv.dig("status", "phase") == "Bound" ||
        pv.dig("spec", "persistentVolumeReclaimPolicy") == "Retain"
    end

    if unmigrated.any?
      pv_names = unmigrated.map { |pv| pv.dig("metadata", "name") }
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
    Page.from_tag_parts("KubernetesMetricsBacklogHigh", kubernetes_node.id)&.incr_resolve
    kubernetes_node.vm.incr_destroy
    kubernetes_node.destroy
    cluster.incr_sync_internal_dns_config
    cluster.incr_sync_worker_mesh
    cluster.incr_update_billing_records
    pop "kubernetes node is deleted"
  end

  def available?
    kubernetes_node.available?
  end

  def node_pvs
    pvs = JSON.parse(cluster.client.kubectl("get pv -ojson"))["items"]
    pvs.select do |pv|
      pv.dig("spec", "csi", "driver") == "csi.ubicloud.com" &&
        pv.dig("spec", "nodeAffinity", "required", "nodeSelectorTerms", 0, "matchExpressions", 0, "values", 0) == kubernetes_node.name
    end
  end
end
