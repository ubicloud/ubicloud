# frozen_string_literal: true

class Kubernetes::Client
  SERVICE_FINALIZER = "k8s.ubicloud.com/load-balancer"

  def initialize(kubernetes_cluster, session)
    @session = session
    @kubernetes_cluster = kubernetes_cluster
  end

  def lb_name_for_svc
    @kubernetes_cluster.ubid
  end

  def is_service_deleted(svc)
    svc.dig("metadata", "deletionTimestamp")
  end

  def is_service_finalized(svc)
    svc.dig("metadata", "finalizers")&.include?(SERVICE_FINALIZER)
  end

  # Returning an array in this format:
  # [[src_port_0, dst_port_0], [src_port_1, dst_port_1],...]
  def lb_desired_ports(svc)
    svc["spec"]["ports"].map { |port| [port["port"], port["nodePort"]] }
  end

  def is_load_balancer_hostname_set(svc)
    !svc.dig("status", "loadBalancer", "ingress", "hostname").to_s.empty?
  end

  def kubectl(cmd)
    @session.exec!("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf #{cmd}")
  end

  def set_load_balancer_host_name(svc, hostname)
    kubectl("-n #{svc["metadata"]["namespace"]} patch service #{svc["metadata"]["name"]} --type='merge' -p '{\"status\":{\"loadBalancer\":{\"ingress\":[{\"hostname\":\"#{hostname}\"}]}}}' --subresource='status'")
  end

  def add_svc_finalizer(svc)
    kubectl("-n #{svc["metadata"]["namespace"]} patch service #{svc["metadata"]["name"]} --type='merge' -p '{\"metadata\":{\"finalizers\":[\"#{SERVICE_FINALIZER}\"]}}'")
  end

  def remove_svc_finalizer(svc)
    kubectl("-n #{svc["metadata"]["namespace"]} patch service #{svc["metadata"]["name"]} --type='json' -p='[{\"op\": \"remove\", \"path\": \"/metadata/finalizers\",\"value\":[\"#{SERVICE_FINALIZER}\"]}]'")
  end

  def vm_diff_for_lb(lb)
    worker_vms = @kubernetes_cluster.nodepools.flat_map(&:vms)
    worker_vm_ids = worker_vms.map(&:id).to_set
    lb_vms = lb.load_balancers_vms.map(&:vm)
    lb_vm_ids = lb_vms.map(&:id).to_set

    extra_vms = lb_vms.reject { |vm| worker_vm_ids.include?(vm.id) }
    missing_vms = worker_vms.reject { |vm| lb_vm_ids.include?(vm.id) }
    [extra_vms, missing_vms]
  end

  def port_diff_for_lb(lb, desired_ports)
    lb_ports_hash = lb.ports.to_h { |p| [[p.src_port, p.dst_port], p.id] }
    missing_ports = desired_ports - lb_ports_hash.keys
    extra_ports = (lb_ports_hash.keys - desired_ports).map { |p| LoadBalancerPort[id: lb_ports_hash[p]] }

    [extra_ports, missing_ports]
  end

  def lb_service_modified?(svc)
    return true if is_service_deleted(svc) && is_service_finalized(svc)

    lb = LoadBalancer.where(name: lb_name_for_svc).first
    return true unless lb

    extra_vms, missing_vms = vm_diff_for_lb(lb)
    return true unless extra_vms.empty? && missing_vms.empty?

    extra_ports, missing_ports = port_diff_for_lb(lb, lb_desired_ports(svc))
    return true unless extra_ports.empty? && missing_ports.empty?

    is_load_balancer_hostname_set(svc)
  end

  def any_lb_services_modified?
    k8s_svc_raw = kubectl("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson")
    found = JSON.parse(k8s_svc_raw)["items"].find { |svc| lb_service_modified?(svc) }
    !!found
  end

  def reconcile_kubernetes_service_deletion(svc)
    LoadBalancer.where(name: lb_name_for_svc).first&.incr_destroy
    remove_svc_finalizer(svc)
  end

  def reconcile_kubernetes_service(svc)
    return reconcile_kubernetes_service_deletion(svc) if is_service_deleted(svc)
    add_svc_finalizer(svc)

    name = lb_name_for_svc
    desired_ports = lb_desired_ports(svc)
    lb = LoadBalancer.where(name:).first
    if lb.nil?
      lb = Prog::Vnet::LoadBalancerNexus.assemble_with_multiple_ports(@kubernetes_cluster.private_subnet.id, ports: desired_ports, name:, algorithm: "hash_based",
        health_check_protocol: "tcp", stack: LoadBalancer::Stack::IPV4).subject
    end

    extra_vms, missing_vms = vm_diff_for_lb(lb)
    missing_vms.each { |missing_vm| lb.add_vm(missing_vm) }
    extra_vms.each { |extra_vm| lb.detach_vm(extra_vm) }

    extra_ports, missing_ports = port_diff_for_lb(lb, desired_ports)
    extra_ports.each { |port| lb.remove_port(port) }
    missing_ports.each { |port| lb.add_port(port) }

    set_load_balancer_host_name(svc, lb.hostname) if lb.strand.label == "wait"
  end

  def sync_kubernetes_services
    k8s_svc_raw = kubectl("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson")
    JSON.parse(k8s_svc_raw)["items"].each do |svc|
      reconcile_kubernetes_service(svc)
    end
  end
end
