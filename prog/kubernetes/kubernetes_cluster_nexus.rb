# frozen_string_literal: true

class Prog::Kubernetes::KubernetesClusterNexus < Prog::Base
  subject_is :kubernetes_cluster
  semaphore :destroy

  def self.assemble(name:, kubernetes_version:, private_subnet_id:, project_id:, location:, replica: 3)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing project"
      end

      kc = KubernetesCluster.create_with_id(
        name: name,
        kubernetes_version: kubernetes_version,
        replica: replica,
        private_subnet_id: UBID.to_uuid(private_subnet_id),
        location: location
      )

      kc.associate_with_project(project)
      Strand.create(prog: "Kubernetes::KubernetesClusterNexus", label: "start") { _1.id = kc.id }
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

  def first_control_plane
    kubernetes_cluster.vms.first
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    hop_create_infrastructure
  end

  label def create_infrastructure
    # Question: should we manage the subnet or let the customer decide which one we will use.
    hop_create_loadbalancer
  end

  label def create_loadbalancer
    hop_bootstrap_first_control_plane unless kubernetes_cluster.load_balancer.nil?

    load_balancer_st = Prog::Vnet::LoadBalancerNexus.assemble(
      kubernetes_cluster.private_subnet_id,
      name: "#{kubernetes_cluster.name}-apiserver",
      algorithm: "hash_based",
      src_port: 443,
      dst_port: 6443,
      health_check_endpoint: "/healthz",
      health_check_protocol: "tcp"
    )
    kubernetes_cluster.update(load_balancer_id: load_balancer_st.id)
    hop_bootstrap_control_plane_vm
  end

  label def bootstrap_control_plane_vm
    nap 5 if kubernetes_cluster.load_balancer.hostname.nil?

    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi",
      kubernetes_cluster.projects.first.id,
      # we should reiterate how we name the vm. some how correlate it to the vm's info.
      name: "#{kubernetes_cluster.name.downcase}-control-plane-#{SecureRandom.alphanumeric(5).downcase}",
      location: kubernetes_cluster.location,
      size: "standard-2",
      boot_image: "ubuntu-jammy",
      private_subnet_id: kubernetes_cluster.private_subnet_id,
      enable_ip4: true
    )
    # TODO: fix later
    DB[:kubernetes_clusters_vm].insert(SecureRandom.uuid, kubernetes_cluster.id, vm_st.subject.id)
    kubernetes_cluster.load_balancer.add_vm(vm_st.subject)
    # add another prog to make modular
    set_current_vm(vm_st.subject.ubid)
    hop_install_prerequistes_on_control_plane
  end

  label def install_prerequistes_on_control_plane
    current_vm.sshable.cmd <<BASH
set -ueo pipefail
sudo mkdir -p /etc/kubernetes/pki/etcd
sudo mkdir -p /run/cluster-api
sudo mkdir -p /run/kubeadm
sudo sed -i '/^#net\\.ipv4\\.ip_forward=1/s/^#//' /etc/sysctl.conf
sudo sysctl -p
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
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
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
      hop_bootstrap_cluster
    end

    push Prog::BootstrapRhizome, {"target_folder" => "kubernetes", "subject_id" => current_vm.sshable.id, "user" => current_vm.unix_user}
  end

  label def bootstrap_cluster
    hop_init_the_cluster if kubernetes_cluster.vms.count == 1

    hop_join_control_plane_vm
  end

  label def init_the_cluster
    case current_vm.sshable.cmd("common/bin/daemonizer --check init_kubernetes_cluster")
    when "Succeeded"
      hop_install_cni
    when "NotStarted", "Failed"
      current_vm.sshable.cmd("common/bin/daemonizer 'sudo /home/ubi/kubernetes/bin/init-cluster #{kubernetes_cluster.name} #{kubernetes_cluster.load_balancer.hostname}' init_kubernetes_cluster")
      nap 10
      # when "Failed"
      # probably register deadline
      #   fail "could not init control-plane cluster"
      # maybe page someone. read logs
    when "InProgress"
      nap 10
    end
  end

  label def install_cni
    # first question: should we do it here?
    # second question: how should we do it?
    # maybe for now:
    # sshable.cmd("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf create -f https://cni-installation-url")
    hop_complete_cluster_bootstrap
  end

  label def complete_cluster_bootstrap
    if kubernetes_cluster.vms.count >= 3
      hop_wait
    end

    upload_cert_output = first_control_plane.sshable.cmd("sudo kubeadm init phase upload-certs --upload-certs")
    set_frame("join_token", first_control_plane.sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication"))
    set_frame("certificate_key", upload_cert_output[/certificate key: (.*)/, 1])
    set_frame("discovery_token_ca_cert_hash", upload_cert_output[/discovery-token-ca-cert-hash sha256: (.*)/, 1])
    hop_bootstrap_control_plane_vm
  end

  label def join_control_plane_vm
    case current_vm.sshable.cmd("common/bin/daemonizer --check join_control_plane")
    when "Succeeded"
      hop_complete_cluster_bootstrap
    when "NotStarted", "Failed"
      current_vm.sshable.cmd("common/bin/daemonizer 'sudo kubernetes/bin/join-control-plane-node ##{kubernetes_cluster.load_balancer.hostname} #{frame["join_token"]} #{frame["discovery_token_ca_cert_hash"]} #{frame["certificate_key"]}' join_control_plane")
      # when "Failed"
      #   fail "could not join control-plane node"
      # maybe page someone. read logs
    when "InProgress"
      nap 10
    end
  end

  label def wait
    nap 30
  end

  label def destroy
    kubernetes_cluster.load_balancer.incr_destroy
    kubernetes_cluster.vms.map(&:incr_destroy)
    kubernetes_cluster.projects.map { kubernetes_cluster.dissociate_with_project(_1) }
    pop "kubernetes cluster is deleted"
  end
end
