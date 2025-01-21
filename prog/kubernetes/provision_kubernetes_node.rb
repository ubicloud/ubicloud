# frozen_string_literal: true

class Prog::Kubernetes::ProvisionKubernetesNode < Prog::Base
  subject_is :kubernetes_cluster

  def vm
    @vm ||= Vm[frame.fetch("vm_id", nil)] || nil
  end

  def write_hosts_file_if_needed(ip = nil)
    return unless Config.development?
    return if vm.sshable.cmd("sudo cat /etc/hosts").match?(/#{kubernetes_cluster.endpoint}/)
    ip = kubernetes_cluster.cp_vms.first.ephemeral_net4 if ip.nil?

    vm.sshable.cmd("echo '#{ip} #{kubernetes_cluster.endpoint}' | sudo tee -a /etc/hosts")
  end

  label def start
    name = "#{kubernetes_cluster.name.downcase}-control-plane-#{SecureRandom.alphanumeric(5).downcase}"

    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      "ubi",
      Config.kubernetes_service_project_id,
      # we should reiterate how we name the vm. some how correlate it to the vm's info.
      name: name,
      location: kubernetes_cluster.location,
      size: "standard-2",
      boot_image: "ubuntu-jammy",
      private_subnet_id: kubernetes_cluster.private_subnet_id,
      enable_ip4: true
    )

    current_frame = strand.stack.first
    current_frame["vm_id"] = vm_st.id
    strand.modified!(:stack)

    kubernetes_cluster.add_cp_vm(vm_st.subject)
    kubernetes_cluster.api_server_lb.add_vm(vm_st.subject)

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
  curl -fsSL https://pkgs.k8s.io/core:/stable:/#{kubernetes_cluster.kubernetes_version}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/#{kubernetes_cluster.kubernetes_version}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
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

    hop_init_cluster if kubernetes_cluster.cp_vms.count == 1

    hop_join_control_plane
  end

  label def init_cluster
    case vm.sshable.cmd("common/bin/daemonizer --check init_kubernetes_cluster")
    when "Succeeded"
      pop vm_id: vm.id
    when "NotStarted"
      ps = kubernetes_cluster.private_subnet
      vm.sshable.cmd("common/bin/daemonizer '/home/ubi/kubernetes/bin/init-cluster #{kubernetes_cluster.name} #{kubernetes_cluster.endpoint} 443 #{ps.net4} #{ps.net6} #{vm.nics.first.private_ipv4}' init_kubernetes_cluster")
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
      pop vm_id: vm.id
    when "NotStarted"
      cp_sshable = kubernetes_cluster.cp_vms.first.sshable
      join_token = cp_sshable.cmd("sudo kubeadm token create --ttl 24h --usages signing,authentication").tr("\n", "")
      certificate_key = cp_sshable.cmd("sudo kubeadm init phase upload-certs --upload-certs")[/certificate key:\n(.*)/, 1]
      discovery_token_ca_cert_hash = cp_sshable.cmd("sudo kubeadm token create --print-join-command")[/discovery-token-ca-cert-hash (.*)/, 1]

      vm.sshable.cmd("common/bin/daemonizer 'kubernetes/bin/join-control-plane-node #{kubernetes_cluster.endpoint}:443 #{join_token} #{discovery_token_ca_cert_hash} #{certificate_key}' join_control_plane")
      nap 15
    when "InProgress"
      nap 10
    when "Failed"
      # TODO: Create a page
      Clog.emit("JOIN CLUSTER FAILED")
      nap 65536
    end

    nap 65536
  end
end
