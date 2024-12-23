# frozen_string_literal: true

class Prog::Kubernetes::KubernetesNodepoolNexus < Prog::Base
  subject_is :kubernetes_nodepool
  semaphore :destroy

  def self.assemble(name:, kubernetes_version:, project_id:, location:, replica:, kubernetes_cluster_id:)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      kn = KubernetesNodepool.create_with_id(
        name: name,
        kubernetes_version: kubernetes_version,
        replica: replica,
        location: location,
        kubernetes_cluster_id: kubernetes_cluster_id
      )

      kn.associate_with_project(project)
      Strand.create(prog: "Kubernetes::KubernetesNodepoolNexus", label: "start") { _1.id = kn.id }
    end
  end

  def set_frame(key, value)
    current_frame = strand.stack.first
    current_frame[key] = value
    strand.modified!(:stack)
    strand.save_changes
  end

  def set_current_vm(id)
    set_frame("current_vm", id)
  end

  def current_vm
    Vm[frame["current_vm"]]
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    hop_bootstrap_worker_vm
  end

  label def bootstrap_worker_vm
    nap 5 if kubernetes_nodepool.kubernetes_cluster.load_balancer.hostname.nil?

    if kubernetes_nodepool.vms.count >= kubernetes_nodepool.replica
      hop_wait
    end

    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi",
      kubernetes_nodepool.projects.first.id,
      name: "#{kubernetes_nodepool.kubernetes_cluster.name.downcase}-#{kubernetes_nodepool.name}-#{SecureRandom.alphanumeric(5).downcase}",
      location: kubernetes_nodepool.location,
      size: "standard-2",
      boot_image: "ubuntu-jammy",
      private_subnet_id: kubernetes_nodepool.kubernetes_cluster.private_subnet_id,
      enable_ip4: true
    )
    # TODO: fix later
    DB[:kubernetes_nodepools_vm].insert(SecureRandom.uuid, kubernetes_nodepool.id, vm_st.subject.id)
    set_current_vm(vm_st.subject.ubid)
    hop_install_prerequistes_on_worker
  end

  label def install_prerequistes_on_worker
    current_vm.sshable.cmd <<BASH
set -ueo pipefail
echo "net.ipv6.conf.all.forwarding=1\nnet.ipv6.conf.all.proxy_ndp=1\nnet.ipv4.conf.all.forwarding=1\nnet.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/72-clover-forward-packets.conf
sudo sysctl --system
sudo modprobe br_netfilter
sudo apt update
sudo apt install -y ca-certificates curl apt-transport-https gpg
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \\$(. /etc/os-release && echo "\\$VERSION_CODENAME") stable" \\| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y containerd
sudo mkdir /etc/containerd
sudo touch /etc/containerd/config.toml
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
curl -fsSL https://pkgs.k8s.io/core:/stable:/#{kubernetes_nodepool.kubernetes_version}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/#{kubernetes_nodepool.kubernetes_version}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
BASH
    hop_upload_rhizome
  end

  label def upload_rhizome
    if retval&.dig("msg") == "rhizome user bootstrapped and source installed"
      strand.update(retval: nil)
      hop_bootstrap_worker
    end

    push Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => current_vm.sshable.id, "user" => current_vm.unix_user}
  end

  label def bootstrap_worker
    first_control_plane = kubernetes_nodepool.kubernetes_cluster.vms.first
    set_frame("join_token", first_control_plane.sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication").tr("\n", ""))
    set_frame("discovery_token_ca_cert_hash", first_control_plane.sshable.cmd("sudo kubeadm token create --print-join-command")[/discovery-token-ca-cert-hash (.*)/, 1])
    hop_join_worker
  end

  label def join_worker
    case current_vm.sshable.cmd("common/bin/daemonizer --check join_worker")
    when "Succeeded"
      hop_install_cni
    when "NotStarted", "Failed"
      current_vm.sshable.cmd("common/bin/daemonizer 'sudo kubernetes/bin/join-worker-node #{kubernetes_nodepool.kubernetes_cluster.endpoint}:443 #{frame["join_token"]} #{frame["discovery_token_ca_cert_hash"]}' join_worker")
      nap 5
    when "InProgress"
      nap 10
    end
  end

  label def install_cni
    script = <<BASH_SCRIPT
#!/bin/bash
cd /home/ubi || {
    echo "Failed to change directory to /home/ubi" >&2
    exit 1
}
exec ./kubernetes/bin/ubicni
BASH_SCRIPT
    current_vm.sshable.cmd("sudo tee -a /opt/cni/bin/ubicni", stdin: script)
    current_vm.sshable.cmd("sudo chmod +x /opt/cni/bin/ubicni")
    cni_config = <<CONFIG
{
"cniVersion": "1.0.0",
"name": "ubicni-network",
"type": "ubicni",
"ipam": {
  "type": "host-local",
  "ranges": [
    {
      "subnet_ula_ipv6": "#{current_vm.nics.first.private_ipv6}",
      "subnet_ipv6": "#{current_vm.ephemeral_net6}",
      "subnet_ipv4": "#{current_vm.nics.first.private_ipv4}"
    }
  ]
}
}
CONFIG
    current_vm.sshable.cmd("sudo tee -a /etc/cni/net.d/ubicni-config.json", stdin: cni_config)
    hop_bootstrap_worker_vm
  end

  label def wait
    nap 10
  end

  label def destroy
    kubernetes_nodepool.vms.map(&:incr_destroy)
    kubernetes_nodepool.projects.map { kubernetes_nodepool.dissociate_with_project(_1) }
    kubernetes_nodepool.destroy
    pop "kubernetes nodepool is deleted"
  end
end
