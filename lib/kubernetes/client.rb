# frozen_string_literal: true

class Kubernetes::Client
  def initialize(kubernetes_cluster, session)
    @session = session
    @kubernetes_cluster = kubernetes_cluster
    @load_balancer = kubernetes_cluster.services_lb
  end

  def service_deleted?(svc)
    !!svc.dig("metadata", "deletionTimestamp")
  end

  # Returns a flat array of [port, nodePort] pairs from all services
  # Deduplicates based on the 'port' value, keeping only the first occurrence
  # Format: [[src_port_0, dst_port_0], [src_port_1, dst_port_1], ...]
  def lb_desired_ports(svc_list)
    seen_ports = {}
    sorted = svc_list.sort_by { |svc| svc["metadata"]["creationTimestamp"] }
    sorted.each do |svc|
      svc.dig("spec", "ports")&.each do |port|
        seen_ports[port["port"]] ||= port["nodePort"]
      end
    end

    seen_ports.to_a
  end

  def load_balancer_hostname_missing?(svc)
    svc.dig("status", "loadBalancer", "ingress")&.first&.dig("hostname").to_s.empty?
  end

  def kubectl(cmd, **)
    output = @session.exec!(NetSsh.combine("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s", cmd), **)
    raise output if output.exitstatus != 0

    output
  end

  def version
    kubectl("version --client")[/Client Version: (v1\.\d\d)\.\d/, 1]
  end

  def delete_node(node_name)
    kubectl("delete node :node_name", node_name:)
  end

  def retain_pv(pv_name)
    patch_data = JSON.generate({"spec" => {"persistentVolumeReclaimPolicy" => "Retain"}})
    kubectl("patch pv :pv_name --type=merge -p :patch_data", pv_name:, patch_data:)
  end

  def get_csr(node_name, csr_status:)
    kubectl("get csr --sort-by=.metadata.creationTimestamp | awk /:csr_status/' && /kubelet-serving/ && /':node_name'/ {print $1}' | tail -1", node_name:, csr_status:).chomp
  end

  def approve_csr(csr_name)
    kubectl("certificate approve :csr_name", csr_name:)
  end

  def set_load_balancer_hostname(svc, hostname)
    patch_data = JSON.generate({
      "status" => {
        "loadBalancer" => {
          "ingress" => [{"hostname" => hostname}],
        },
      },
    })
    kubectl("-n :namespace patch service :service --type=merge -p :patch_data --subresource=status",
      namespace: svc.dig("metadata", "namespace"),
      service: svc.dig("metadata", "name"),
      patch_data:)
  end

  def sync_kubernetes_services
    k8s_svc_raw = kubectl("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson")
    svc_list = JSON.parse(k8s_svc_raw)["items"]

    if @load_balancer.nil?
      raise "services load balancer does not exist."
    end

    extra_vms, missing_vms = @kubernetes_cluster.vm_diff_for_lb(@load_balancer)
    missing_vms.each { |missing_vm| @load_balancer.add_vm(missing_vm) }
    extra_vms.each { |extra_vm| @load_balancer.detach_vm(extra_vm) }

    extra_ports, missing_ports = @kubernetes_cluster.port_diff_for_lb(@load_balancer, lb_desired_ports(svc_list))
    extra_ports.each { |port| @load_balancer.remove_port(port) }
    missing_ports.each { |port| @load_balancer.add_port(port[0], port[1]) }

    sync_lb_firewall_rules

    return unless @load_balancer.strand.label == "wait"

    svc_list.each { |svc| set_load_balancer_hostname(svc, @load_balancer.hostname) }
  end

  def sync_lb_firewall_rules
    extra_rules, missing_keys = @kubernetes_cluster.firewall_rule_diff_for_lb(@load_balancer)
    return if extra_rules.empty? && missing_keys.empty?

    firewall = @kubernetes_cluster.internal_worker_vm_firewall
    extra_rules.each { |r| firewall.remove_firewall_rule(r) }
    missing_keys.each { |(cidr, port)| firewall.insert_firewall_rule(cidr, Sequel.pg_range(port..port), description: "k8s-svc-lb:#{port}") }
    firewall.vms.each(&:incr_update_firewall_rules)
  end

  def any_lb_services_modified?
    k8s_svc_raw = kubectl("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson")
    svc_list = JSON.parse(k8s_svc_raw)["items"]
    @load_balancer.reload
    @kubernetes_cluster.reload

    return true if svc_list.empty? && !@load_balancer.ports.empty?

    extra_vms, missing_vms = @kubernetes_cluster.vm_diff_for_lb(@load_balancer)
    return true unless extra_vms.empty? && missing_vms.empty?

    extra_ports, missing_ports = @kubernetes_cluster.port_diff_for_lb(@load_balancer, lb_desired_ports(svc_list))
    return true unless extra_ports.empty? && missing_ports.empty?

    svc_list.any? { |svc| load_balancer_hostname_missing?(svc) }
  end
end
