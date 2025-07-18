# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::Kubernetes < Prog::Test::Base
  semaphore :destroy

  def self.assemble
    kubernetes_test_project = Project.create(name: "Kubernetes-Test-Project")
    kubernetes_service_project = Project.create_with_id(Config.kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources")

    Strand.create(
      prog: "Test::Kubernetes",
      label: "start",
      stack: [{
        "kubernetes_service_project_id" => kubernetes_service_project.id,
        "kubernetes_test_project_id" => kubernetes_test_project.id
      }]
    )
  end

  label def start
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "kubernetes-test-standard",
      project_id: frame["kubernetes_test_project_id"],
      location_id: Location::HETZNER_FSN1_ID,
      version: Option.kubernetes_versions.first,
      cp_node_count: 1
    ).subject
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
      name: "kubernetes-test-standard-nodepool",
      node_count: 1,
      kubernetes_cluster_id: kc.id,
      target_node_size: "standard-2"
    )

    update_stack({"kubernetes_cluster_id" => kc.id})
    hop_update_loadbalancer_hostname
  end

  label def update_loadbalancer_hostname
    nap 5 unless kubernetes_cluster.api_server_lb
    kubernetes_cluster.api_server_lb.update(custom_hostname: "k8s-e2e-test.ubicloud.test")
    hop_update_cp_vm_hosts_entries
  end

  label def update_cp_vm_hosts_entries
    cp_vm = kubernetes_cluster.cp_vms.first
    nap 5 unless vm_ready?(cp_vm)
    ensure_hosts_entry(cp_vm.sshable, kubernetes_cluster.api_server_lb.hostname)
    hop_update_worker_hosts_entries
  end

  label def update_worker_hosts_entries
    vm = kubernetes_cluster.nodepools.first.vms.first
    nap 5 unless vm_ready?(vm)
    ensure_hosts_entry(vm.sshable, kubernetes_cluster.api_server_lb.hostname)
    hop_wait_for_kubernetes_bootstrap
  end

  label def wait_for_kubernetes_bootstrap
    hop_test_kubernetes if kubernetes_cluster.strand.label == "wait"
    nap 10
  end

  label def test_kubernetes
    begin
      nodes_output = kubernetes_cluster.client.kubectl("get nodes")
    rescue RuntimeError => ex
      update_stack({"fail_message" => "Failed to run test kubectl command: #{ex.message}"})
      hop_destroy_kubernetes
    end
    missing_nodes = []
    kubernetes_cluster.all_nodes.each { |node|
      missing_nodes.append(node.name) unless nodes_output.include?(node.name)
    }
    update_stack({"fail_message" => "node #{missing_nodes.join(", ")} not found in cluster"}) if missing_nodes.any?
    hop_destroy_kubernetes
  end

  label def destroy_kubernetes
    kubernetes_cluster.incr_destroy
    hop_destroy
  end

  label def destroy
    nap 5 if kubernetes_cluster
    kubernetes_test_project.destroy

    fail_test(frame["fail_message"]) if frame["fail_message"]

    pop "Kubernetes tests are finished!"
  end

  def ensure_hosts_entry(sshable, api_hostname)
    host_line = "#{kubernetes_cluster.sshable.host} #{api_hostname}"
    output = sshable.cmd("cat /etc/hosts")
    unless output.include?(host_line)
      sshable.cmd("echo #{host_line.shellescape} | sudo tee -a /etc/hosts > /dev/null")
    end
  end

  def vm_ready?(vm)
    return false unless vm
    vm.sshable.cmd("uptime")
    true
  rescue
    false
  end

  def kubernetes_test_project
    @kubernetes_test_project ||= Project.with_pk(frame["kubernetes_test_project_id"])
  end

  def kubernetes_cluster
    @kubernetes_cluster ||= KubernetesCluster.with_pk(frame["kubernetes_cluster_id"])
  end
end
