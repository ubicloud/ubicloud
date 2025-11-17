# frozen_string_literal: true

class Prog::Kubernetes::ProvisionKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def node
    @node ||= KubernetesNode[frame["node_id"]]
  end

  def kubernetes_nodepool
    return @kubernetes_nodepool if defined?(@kubernetes_nodepool)
    @kubernetes_nodepool = KubernetesNodepool[frame["nodepool_id"]]
  end

  def vm
    @vm ||= node.vm
  end

  # We need to create a random ula cidr for the cluster services subnet with
  # a NetMask of /108
  # For reference read here:
  # https://github.com/kubernetes/kubernetes/blob/44c230bf5c321056e8bc89300b37c497f464f113/cmd/kubeadm/app/constants/constants.go#L251-L255
  # This is an excerpt from the link:
  # MaximumBitsForServiceSubnet defines maximum possible size of the service subnet in terms of bits.
  # For example, if the value is 20, then the largest supported service subnet is /12 for IPv4 and /108 for IPv6.
  # Note however that anything in between /108 and /112 will be clamped to /112 due to the limitations of the underlying allocation logic.
  # MaximumBitsForServiceSubnet = 20
  def random_ula_cidr
    random_bytes = 0xfd.chr + SecureRandom.bytes(13)
    high_bits = random_bytes[0...8].unpack1("Q>")
    low_bits = (random_bytes[8...14] + "\x00\x00").unpack1("Q>")
    network_address = NetAddr::IPv6.new((high_bits << 64) | low_bits)
    NetAddr::IPv6Net.new(network_address, NetAddr::Mask128.new(108))
  end

  def before_run
    if kubernetes_cluster.strand.label == "destroy" && strand.label != "destroy"
      pop "provisioning canceled"
    end
  end

  label def start
    name, vm_size, storage_size_gib = if kubernetes_nodepool
      ["#{kubernetes_nodepool.ubid}-#{SecureRandom.alphanumeric(5).downcase}",
        kubernetes_nodepool.target_node_size,
        kubernetes_nodepool.target_node_storage_size_gib]
    else
      ["#{kubernetes_cluster.ubid}-#{SecureRandom.alphanumeric(5).downcase}",
        kubernetes_cluster.target_node_size,
        kubernetes_cluster.target_node_storage_size_gib]
    end

    storage_volumes = [{encrypted: true, size_gib: storage_size_gib}] if storage_size_gib

    boot_image = "kubernetes-#{kubernetes_cluster.version.tr(".", "_")}"

    node = Prog::Kubernetes::KubernetesNodeNexus.assemble(
      Config.kubernetes_service_project_id,
      sshable_unix_user: "ubi",
      name: name,
      location_id: kubernetes_cluster.location.id,
      size: vm_size,
      storage_volumes: storage_volumes,
      boot_image: boot_image,
      private_subnet_id: kubernetes_cluster.private_subnet_id,
      enable_ip4: true,
      kubernetes_cluster_id: kubernetes_cluster.id,
      kubernetes_nodepool_id: kubernetes_nodepool&.id
    ).subject
    vm = node.vm

    current_frame = strand.stack.first
    current_frame["node_id"] = node.id
    strand.modified!(:stack)

    unless kubernetes_nodepool
      kubernetes_cluster.api_server_lb.add_vm(vm)
    end

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    nap 5 unless vm.strand.label == "wait"

    vm.sshable.cmd "sudo iptables-nft -t nat -A POSTROUTING -s #{vm.nics.first.private_ipv4} -o ens3 -j MASQUERADE"
    vm.sshable.cmd("sudo nft --file -", stdin: <<TEMPLATE)
table ip6 pod_access;
delete table ip6 pod_access;
table ip6 pod_access {
  chain ingress_egress_control {
    type filter hook forward priority filter; policy drop;
    # allow access to the vm itself in order to not break the normal functionality of Clover and SSH
    ip6 daddr #{vm.ip6} ct state established,related,new counter accept
    ip6 saddr #{vm.ip6} ct state established,related,new counter accept

    # not allow new connections from internet but allow new connections from inside
    ip6 daddr #{vm.ephemeral_net6} ct state established,related counter accept
    ip6 saddr #{vm.ephemeral_net6} ct state established,related,new counter accept

    # used for internal private ipv6 communication between pods
    ip6 saddr #{kubernetes_cluster.private_subnet.net6} ct state established,related,new counter accept
    ip6 daddr #{kubernetes_cluster.private_subnet.net6} ct state established,related,new counter accept
  }
}
TEMPLATE
    vm.sshable.cmd "sudo systemctl enable --now kubelet"

    bud Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => vm.id, "user" => "ubi"}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap(:assign_role)
  end

  label def assign_role
    hop_join_worker if kubernetes_nodepool

    hop_init_cluster if kubernetes_cluster.nodes.count == 1

    hop_join_control_plane
  end

  label def init_cluster
    case vm.sshable.d_check("init_kubernetes_cluster")
    when "Succeeded"
      hop_install_cni
    when "NotStarted"
      params = {
        node_name: vm.name,
        cluster_name: kubernetes_cluster.name,
        lb_hostname: kubernetes_cluster.endpoint,
        port: "443",
        private_subnet_cidr4: kubernetes_cluster.private_subnet.net4,
        private_subnet_cidr6: kubernetes_cluster.private_subnet.net6,
        node_ipv4: vm.private_ipv4,
        node_ipv6: vm.ip6,
        service_subnet_cidr6: random_ula_cidr
      }
      vm.sshable.d_run("init_kubernetes_cluster", "/home/ubi/kubernetes/bin/init-cluster", stdin: JSON.generate(params), log: false)
      nap 30
    when "InProgress"
      nap 10
    when "Failed"
      Clog.emit("INIT CLUSTER FAILED")
      nap 65536
      # TODO: register deadline
    end

    nap 65536
  end

  label def join_control_plane
    case vm.sshable.d_check("join_control_plane")
    when "Succeeded"
      hop_install_cni
    when "NotStarted"
      cp_sshable = kubernetes_cluster.sshable
      params = {
        is_control_plane: true,
        node_name: vm.name,
        endpoint: "#{kubernetes_cluster.endpoint}:443",
        join_token: cp_sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).chomp,
        certificate_key: cp_sshable.cmd("sudo kubeadm init phase upload-certs --upload-certs", log: false)[/certificate key:\n(.*)/, 1],
        discovery_token_ca_cert_hash: cp_sshable.cmd("sudo kubeadm token create --print-join-command", log: false)[/discovery-token-ca-cert-hash (\S+)/, 1],
        node_ipv4: vm.private_ipv4,
        node_ipv6: vm.ip6
      }
      vm.sshable.d_run("join_control_plane", "kubernetes/bin/join-node", stdin: JSON.generate(params), log: false)
      nap 15
    when "InProgress"
      nap 10
    when "Failed"
      # TODO: Create a page
      Clog.emit("JOIN CP NODE TO CLUSTER FAILED")
      nap 65536
    end

    nap 65536
  end

  label def join_worker
    case vm.sshable.d_check("join_worker")
    when "Succeeded"
      hop_install_cni
    when "NotStarted"
      cp_sshable = kubernetes_cluster.sshable
      params = {
        is_control_plane: false,
        node_name: vm.name,
        endpoint: "#{kubernetes_cluster.endpoint}:443",
        join_token: cp_sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).tr("\n", ""),
        discovery_token_ca_cert_hash: cp_sshable.cmd("sudo kubeadm token create --print-join-command", log: false)[/discovery-token-ca-cert-hash (\S+)/, 1],
        node_ipv4: vm.private_ipv4,
        node_ipv6: vm.ip6
      }
      vm.sshable.d_run("join_worker", "kubernetes/bin/join-node", stdin: JSON.generate(params), log: false)
      nap 15
    when "InProgress"
      nap 10
    when "Failed"
      # TODO: Create a page
      Clog.emit("JOIN WORKER NODE TO CLUSTER FAILED")
      nap 65536
    end

    nap 65536
  end

  label def install_cni
    cni_config = <<CONFIG
{
  "cniVersion": "1.0.0",
  "name": "ubicni-network",
  "type": "ubicni",
  "ranges":{
      "subnet_ipv6": "#{NetAddr::IPv6Net.new(vm.ephemeral_net6.network, NetAddr::Mask128.new(80))}",
      "subnet_ula_ipv6": "#{vm.nics.first.private_ipv6}",
      "subnet_ipv4": "#{vm.nics.first.private_ipv4}"
  }
}
CONFIG
    vm.sshable.cmd("sudo tee /etc/cni/net.d/ubicni-config.json", stdin: cni_config)
    hop_approve_new_csr
  end

  label def approve_new_csr
    kubernetes_cluster.sshable.cmd("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get csr | awk '/Pending/ && /kubelet-serving/ && /'\"#{node.name}\"'/ {print $1}' | xargs -r sudo kubectl --kubeconfig /etc/kubernetes/admin.conf certificate approve")
    kubernetes_cluster.incr_sync_internal_dns_config
    kubernetes_cluster.incr_sync_worker_mesh
    pop({node_id: node.id})
  end
end
