# frozen_string_literal: true

class Kubernetes::Client
  def initialize(kubernetes_cluster, session)
    @session = session
    @kubernetes_cluster = kubernetes_cluster
    @load_balancer = LoadBalancer.where(name: kubernetes_cluster.services_load_balancer_name).first
  end

  def is_service_deleted(svc)
    !!svc.dig("metadata", "deletionTimestamp")
  end

  # Returning an array in this format:
  # [[src_port_0, dst_port_0], [src_port_1, dst_port_1],...]
  def lb_desired_ports(svc)
    svc.dig("spec", "ports").map { |port| [port["port"], port["nodePort"]] }
  end

  def load_balancer_hostname_missing?(svc)
    svc.dig("status", "loadBalancer", "ingress", "hostname").to_s.empty?
  end

  def kubectl(cmd)
    @session.exec!("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf #{cmd}")
  end

  def set_load_balancer_host_name(svc, hostname)
    patch_data = JSON.generate({
      "status" => {
        "loadBalancer" => {
          "ingress" => [{"hostname" => hostname}]
        }
      }
    })
    kubectl("-n #{svc.dig("metadata", "namespace")} patch service #{svc.dig("metadata", "name")} --type=merge -p '#{patch_data}' --subresource=status")
  end

  def sync_kubernetes_services
    k8s_svc_raw = kubectl("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson")
    JSON.parse(k8s_svc_raw)["items"].each do |svc|
      reconcile_kubernetes_service(svc)
    end
  end

  def reconcile_kubernetes_service(svc)
    return if is_service_deleted(svc)

    desired_ports = lb_desired_ports(svc)
    if @load_balancer.nil?
      raise "services LoadBalancer does not exist."
    end

    extra_vms, missing_vms = vm_diff_for_lb
    missing_vms.each { |missing_vm| @load_balancer.add_vm(missing_vm) }
    extra_vms.each { |extra_vm| @load_balancer.detach_vm(extra_vm) }

    extra_ports, missing_ports = port_diff_for_lb(desired_ports)
    extra_ports.each { |port| @load_balancer.remove_port(port) }
    missing_ports.each { |port| @load_balancer.add_port(port[0], port[1]) }

    set_load_balancer_host_name(svc, @load_balancer.hostname) if @load_balancer.strand.label == "wait"
  end

  def vm_diff_for_lb
    worker_vms = @kubernetes_cluster.nodepools.flat_map(&:vms)
    worker_vm_ids = worker_vms.map(&:id).to_set
    lb_vms = @load_balancer.load_balancers_vms.map(&:vm)
    lb_vm_ids = lb_vms.map(&:id).to_set

    extra_vms = lb_vms.reject { |vm| worker_vm_ids.include?(vm.id) }
    missing_vms = worker_vms.reject { |vm| lb_vm_ids.include?(vm.id) }
    [extra_vms, missing_vms]
  end

  def port_diff_for_lb(desired_ports)
    lb_ports_hash = @load_balancer.ports.to_h { |p| [[p.src_port, p.dst_port], p.id] }
    missing_ports = desired_ports - lb_ports_hash.keys
    extra_ports = (lb_ports_hash.keys - desired_ports).map { |p| LoadBalancerPort[id: lb_ports_hash[p]] }

    [extra_ports, missing_ports]
  end

  def any_lb_services_modified?
    k8s_svc_raw = kubectl("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson")
    found = JSON.parse(k8s_svc_raw)["items"].find { |svc| lb_service_modified?(svc) }
    !!found
  end

  def lb_service_modified?(svc)
    return true if is_service_deleted(svc) && is_service_finalized(svc)

    return true unless @load_balancer

    extra_vms, missing_vms = vm_diff_for_lb
    return true unless extra_vms.empty? && missing_vms.empty?

    extra_ports, missing_ports = port_diff_for_lb(lb_desired_ports(svc))
    return true unless extra_ports.empty? && missing_ports.empty?

    load_balancer_hostname_missing?(svc)
  end
end
