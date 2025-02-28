# frozen_string_literal: true

class Prog::Kubernetes::ProvisionKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def vm
    @vm ||= Vm[frame["vm_id"]]
  end

  def kubernetes_nodepool
    @kubernetes_nodepool ||= KubernetesNodepool[frame["nodepool_id"]]
  end

  def write_hosts_file_if_needed(ip = nil)
    return unless Config.development?
    return if vm.sshable.cmd("cat /etc/hosts").include?(kubernetes_cluster.endpoint.to_s)
    ip ||= kubernetes_cluster.sshable.host

    vm.sshable.cmd("sudo tee -a /etc/hosts", stdin: "#{ip} #{kubernetes_cluster.endpoint}\n")
  end

  label def start
    name, vm_size, storage_size_gib = if kubernetes_nodepool
      ["#{kubernetes_nodepool.name}-#{SecureRandom.alphanumeric(5).downcase}",
        kubernetes_nodepool.target_node_size,
        kubernetes_nodepool.target_node_storage_size_gib]
    else
      ["#{kubernetes_cluster.name.downcase}-control-plane-#{SecureRandom.alphanumeric(5).downcase}",
        kubernetes_cluster.target_node_size,
        kubernetes_cluster.target_node_storage_size_gib]
    end

    storage_volumes = [{encrypted: true, size_gib: storage_size_gib}] if storage_size_gib

    vm = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi",
      kubernetes_cluster.project.id,
      name: name,
      location_id: kubernetes_cluster.location.id,
      size: vm_size,
      storage_volumes: storage_volumes,
      boot_image: "ubuntu-jammy",
      private_subnet_id: kubernetes_cluster.private_subnet_id,
      enable_ip4: true
    ).subject

    current_frame = strand.stack.first
    current_frame["vm_id"] = vm.id
    strand.modified!(:stack)

    if kubernetes_nodepool
      kubernetes_nodepool.add_vm(vm)
    else
      kubernetes_cluster.add_cp_vm(vm)
      kubernetes_cluster.api_server_lb.add_vm(vm)
    end

    hop_install_software
  end

  label def install_software
    nap 5 unless vm.strand.label == "wait"
    vm.sshable.cmd <<BASH
  set -ueo pipefail
  echo "net.ipv6.conf.all.forwarding=1\nnet.ipv6.conf.all.proxy_ndp=1\nnet.ipv4.conf.all.forwarding=1\nnet.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/72-clover-forward-packets.conf
  sudo sysctl --system
  sudo apt update
  sudo apt install -y ca-certificates curl apt-transport-https gpg
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \\$(. /etc/os-release && echo "\\$VERSION_CODENAME") stable" \\| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt install -y containerd
  sudo mkdir -p /etc/containerd
  sudo touch /etc/containerd/config.toml
  containerd config default | sudo tee /etc/containerd/config.toml
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd
  curl -fsSL https://pkgs.k8s.io/core:/stable:/#{kubernetes_cluster.version}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/#{kubernetes_cluster.version}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
  sudo apt update
  sudo apt install -y kubelet kubeadm kubectl
  sudo apt-mark hold kubelet kubeadm kubectl
  sudo systemctl enable --now kubelet
BASH

    hop_bootstrap_rhizome
  end

  label def bootstrap_rhizome
    bud Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => vm.id, "user" => "ubi"}

    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_assign_role if leaf?
    donate
  end

  label def assign_role
    write_hosts_file_if_needed

    hop_join_worker if kubernetes_nodepool

    hop_init_cluster if kubernetes_cluster.cp_vms.count == 1

    hop_join_control_plane
  end

  label def init_cluster
    case vm.sshable.cmd("common/bin/daemonizer --check init_kubernetes_cluster")
    when "Succeeded"
      hop_install_cni
    when "NotStarted"
      params = {
        cluster_name: kubernetes_cluster.name,
        lb_hostname: kubernetes_cluster.endpoint,
        port: "443",
        private_subnet_cidr4: kubernetes_cluster.private_subnet.net4,
        private_subnet_cidr6: kubernetes_cluster.private_subnet.net6,
        vm_cidr: vm.nics.first.private_ipv4
      }
      vm.sshable.cmd("common/bin/daemonizer /home/ubi/kubernetes/bin/init-cluster init_kubernetes_cluster", stdin: JSON.generate(params))
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
    case vm.sshable.cmd("common/bin/daemonizer --check join_control_plane")
    when "Succeeded"
      hop_install_cni
    when "NotStarted"
      cp_sshable = kubernetes_cluster.sshable
      params = {
        cluster_endpoint: "#{kubernetes_cluster.endpoint}:443",
        join_token: cp_sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).chomp,
        certificate_key: cp_sshable.cmd("sudo kubeadm init phase upload-certs --upload-certs", log: false)[/certificate key:\n(.*)/, 1],
        discovery_token_ca_cert_hash: cp_sshable.cmd("sudo kubeadm token create --print-join-command", log: false)[/discovery-token-ca-cert-hash (.*)/, 1]
      }
      vm.sshable.cmd("common/bin/daemonizer kubernetes/bin/join-control-plane-node join_control_plane", stdin: JSON.generate(params), log: false)
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
    case vm.sshable.cmd("common/bin/daemonizer --check join_worker")
    when "Succeeded"
      hop_install_cni
    when "NotStarted"
      cp_sshable = kubernetes_cluster.sshable
      params = {
        endpoint: "#{kubernetes_cluster.endpoint}:443",
        join_token: cp_sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication", log: false).tr("\n", ""),
        discovery_token_ca_cert_hash: cp_sshable.cmd("sudo kubeadm token create --print-join-command", log: false)[/discovery-token-ca-cert-hash (.*)/, 1]
      }

      vm.sshable.cmd("common/bin/daemonizer kubernetes/bin/join-worker-node join_worker", stdin: JSON.generate(params), log: false)
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
    vm.sshable.cmd("sudo nft -f -", stdin: <<~BASH)
      add table ip nat;

      table ip nat {
        chain POSTROUTING {
          type nat hook postrouting priority 100;
          policy accept;
          ip saddr #{vm.nics.first.private_ipv4} oifname ens3 masquerade;
        }
      }
    BASH

    pop vm_id: vm.id
  end
end
