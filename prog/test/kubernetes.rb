# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::Kubernetes < Prog::Test::Base
  semaphore :destroy

  def self.assemble
    kubernetes_test_project = Project.create(name: "Kubernetes-Test-Project")
    kubernetes_service_project = Project[Config.kubernetes_service_project_id] ||
      Project.create(name: "Ubicloud-Kubernetes-Resources") do |project|
        project.id = Config.kubernetes_service_project_id
      end

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
    st = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "kubernetes-test-standard",
      project_id: frame["kubernetes_test_project_id"],
      location_id: Location::HETZNER_FSN1_ID,
      version: "v1.33",
      cp_node_count: 1
    )

    update_stack({"kubernetes_cluster_id" => st.id})
    hop_wait_kubernetes_resource
  end

  def ensure_hosts_entry(vm, api_hostname)
    ssh = vm.sshable
    host_line = "#{ssh.host} #{api_hostname}"
    output = ssh.cmd("cat /etc/hosts")
    unless output.include?(host_line)
      ssh.cmd("echo '#{host_line}' | sudo tee -a /etc/hosts > /dev/null")
    end
  end

  label def wait_kubernetes_resource
    if kubernetes_cluster.strand.label == "wait"
      hop_test_kubernetes
    else
      api_hostname = kubernetes_cluster.api_server_lb.hostname
      [
        kubernetes_cluster.cp_vms,
        kubernetes_cluster.worker_vms
      ].each do |vm_group|
        if vm_group.length == 1
          ensure_hosts_entry(vm_group.first, api_hostname)
        end
      end
      nap 10
    end
  end

  label def test_kubernetes
    unless kubernetes_cluster.client.kubectl("get nodes")
      update_stack({"fail_message" => "Failed to run test kubectl command"})
    end

    hop_destroy_kubernetes
  end

  label def destroy_kubernetes
    kubernetes_cluster.incr_destroy
    hop_destroy
  end

  label def destroy
    kubernetes_test_project.destroy

    fail_test(frame["fail_message"]) if frame["fail_message"]

    pop "Kubernetes tests are finished!"
  end

  def kubernetes_test_project
    @kubernetes_test_project ||= Project[frame["kubernetes_test_project_id"]]
  end

  def kubernetes_cluster
    @kubernetes_cluster ||= KubernetesCluster[frame["kubernetes_cluster_id"]]
  end
end
