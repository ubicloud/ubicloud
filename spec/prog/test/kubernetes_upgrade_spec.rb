# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::KubernetesUpgrade do
  subject(:kubernetes_test) {
    described_class.new(Strand.new(prog: "Test::KubernetesUpgrade", label: "start", stack: strand_stack))
  }

  let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id, "worker_node_count" => 1}] }

  let(:kubernetes_service_project_id) { "546a1ed8-53e5-86d2-966c-fb782d2ae3aa" }
  let(:kubernetes_test_project) { Project.create(name: "Kubernetes-Test-Project") }
  let(:kubernetes_service_project) { Project.create_with_id(kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources") }
  let(:session) { Net::SSH::Connection::Session.allocate }
  let(:kubernetes_cluster) {
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "test-cluster",
      version: Option.selectable_kubernetes_versions.last,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: kubernetes_test_project.id,
      cp_node_count: 1,
      target_node_size: "standard-2",
    ).subject
    lb = LoadBalancer.create(private_subnet_id: kc.private_subnet.id, name: "api-lb", health_check_endpoint: "/healthz", project_id: kubernetes_test_project.id)
    kc.update(api_server_lb_id: lb.id)
    kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "test-cluster-np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
    Prog::Kubernetes::KubernetesNodeNexus.assemble(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "cp-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-4", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: Option.selectable_kubernetes_versions.first, enable_ip4: true, kubernetes_cluster_id: kc.id)
    Prog::Kubernetes::KubernetesNodeNexus.assemble(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "w1-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-4", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: Option.selectable_kubernetes_versions.first, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
    kc
  }
  let(:sshable) { kubernetes_test.kubernetes_cluster.sshable }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(kubernetes_service_project.id)
    if (kc = kubernetes_test.kubernetes_cluster)
      allow(kc.sshable).to receive(:connect).and_return(session)
    end
  end

  describe ".assemble" do
    let(:strand_stack) { [{}] }

    it "creates test and service projects and a strand for the upgrade cluster" do
      expect(Config).to receive(:kubernetes_service_project_id).at_least(:once).and_return("4fd01c1a-f022-43e8-bd3d-6dbe214df6ed")
      st = described_class.assemble
      expect(Project["4fd01c1a-f022-43e8-bd3d-6dbe214df6ed"]).not_to be_nil
      expect(Project.where(name: "Kubernetes-Test-Project").count).to eq(1)
      expect(st.prog).to eq("Test::KubernetesUpgrade")
      expect(st.label).to eq("start")
      expect(st.stack.first["cluster_name"]).to eq("kubernetes-test-upgrade")
      expect(st.stack.first["worker_node_count"]).to eq(1)
    end
  end

  describe "#start" do
    let(:strand_stack) { [{"kubernetes_test_project_id" => kubernetes_test_project.id, "cluster_name" => "kubernetes-test-upgrade", "worker_node_count" => 1}] }

    it "assembles a single-worker cluster and hops to wait_for_kubernetes_bootstrap" do
      expect { kubernetes_test.start }.to hop("wait_for_kubernetes_bootstrap")
      expect(kubernetes_test.strand.stack[0]["kubernetes_cluster_id"]).to eq KubernetesCluster.get(:id)
      expect(KubernetesCluster.count).to eq(1)
      expect(KubernetesNodepool.count).to eq(1)
      expect(KubernetesNodepool.first.node_count).to eq(1)
    end
  end

  describe "#wait_for_kubernetes_bootstrap" do
    it "hops to setup_statefulset if cluster is ready" do
      kubernetes_cluster.strand.update(label: "wait")
      expect { kubernetes_test.wait_for_kubernetes_bootstrap }.to hop("setup_statefulset")
    end

    it "naps if cluster is not ready" do
      expect { kubernetes_test.wait_for_kubernetes_bootstrap }.to nap(10)
    end
  end

  describe "#setup_statefulset" do
    it "applies the statefulset and hops to wait_for_statefulset" do
      expect(sshable).to receive(:_cmd).with("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -", stdin: /apiVersion: apps/)
      expect { kubernetes_test.setup_statefulset }.to hop("wait_for_statefulset")
    end
  end

  describe "#wait_for_statefulset" do
    it "naps if pod is not running yet" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").and_return(response)
      expect { kubernetes_test.wait_for_statefulset }.to nap(5)
    end

    it "launches 3 daemonized writes and hops to wait_data_write once the pod is running" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("Running", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").and_return(response)
      (1..3).each do |i|
        unit_name = "csi_data_write_#{i}"
        bash_cmd = "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf exec -t ubuntu-statefulset-0 -- sh -c \"head -c 300M /dev/urandom | tee /etc/data/random-data-#{i} | sha256sum | awk '{print \\$1}'\" > /dev/shm/#{unit_name}.hash"
        expected_cmd = "common/bin/daemonizer2 run #{unit_name} #{["bash", "-c", bash_cmd].shelljoin}"
        expect(sshable).to receive(:_cmd).with(expected_cmd, stdin: nil, log: true)
      end
      expect { kubernetes_test.wait_for_statefulset }.to hop("wait_data_write")
    end
  end

  describe "#wait_data_write" do
    it "naps if any write is still in progress" do
      expect(sshable).to receive(:d_check).with("csi_data_write_1").and_return("InProgress")
      expect { kubernetes_test.wait_data_write }.to nap(30)
    end

    it "fails if a write has failed" do
      expect(sshable).to receive(:d_check).with("csi_data_write_1").and_return("Failed")
      expect { kubernetes_test.wait_data_write }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack[0]["fail_message"]).to eq "daemonized write for random-data-1 failed"
    end

    it "captures the write hashes and hops to trigger_upgrade when all writes have succeeded" do
      (1..3).each do |i|
        expect(sshable).to receive(:d_check).with("csi_data_write_#{i}").and_return("Succeeded")
      end
      (1..3).each do |i|
        expect(sshable).to receive(:_cmd).with("cat /dev/shm/csi_data_write_#{i}.hash").and_return("hash#{i}")
        expect(sshable).to receive(:d_clean).with("csi_data_write_#{i}")
      end
      expect { kubernetes_test.wait_data_write }.to hop("trigger_upgrade")
      expect(kubernetes_test.strand.stack[0]["read_hashes"]).to eq({"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"})
    end
  end

  describe "#trigger_upgrade" do
    it "fails if no upgrade candidate is available" do
      kubernetes_test.kubernetes_cluster.update(version: Option.selectable_kubernetes_versions.first)
      expect { kubernetes_test.trigger_upgrade }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("No upgrade candidate available")
    end

    it "updates version, increments upgrade semaphores, and hops to wait_for_upgrade" do
      target_version = kubernetes_cluster.available_upgrade_version
      expect { kubernetes_test.trigger_upgrade }.to hop("wait_for_upgrade")

      kubernetes_cluster.reload
      expect(kubernetes_cluster.version).to eq(target_version)
      expect(kubernetes_cluster.upgrade_set?).to be true
      expect(kubernetes_cluster.nodepools(reload: true).first.upgrade_set?).to be true
    end
  end

  describe "#wait_for_upgrade" do
    it "naps if the cluster is still upgrading" do
      expect { kubernetes_test.wait_for_upgrade }.to nap(15)
    end

    it "fails if a node is not upgraded to the target version" do
      kubernetes_test.kubernetes_cluster.strand.update(label: "wait")
      Strand.where(id: kubernetes_test.kubernetes_cluster.nodepools_dataset.select(:id)).update(label: "wait")
      kubernetes_test.kubernetes_cluster.update(kubeconfig: "stored")

      nodes_json = {
        "items" => [
          {"status" => {"nodeInfo" => {"kubeletVersion" => "#{kubernetes_test.kubernetes_cluster.version}.1"}}},
          {"status" => {"nodeInfo" => {"kubeletVersion" => "v1.30.1"}}},
        ],
      }
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(nodes_json), 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -o json").and_return(response)

      response_raw = Net::SSH::Connection::Session::StringWithExitstatus.new("nodes_raw", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes").and_return(response_raw)

      expect { kubernetes_test.wait_for_upgrade }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("Not all 2 nodes upgraded to #{kubernetes_cluster.version}:\nnodes_raw")
    end

    it "fails if the node count does not match the cluster nodes" do
      kubernetes_test.kubernetes_cluster.strand.update(label: "wait")
      Strand.where(id: kubernetes_test.kubernetes_cluster.nodepools_dataset.select(:id)).update(label: "wait")
      kubernetes_test.kubernetes_cluster.update(kubeconfig: "stored")

      # Cluster has a control-plane node and one worker (2 nodes); only one
      # reported by kubectl trips the count check.
      nodes_json = {
        "items" => [
          {"status" => {"nodeInfo" => {"kubeletVersion" => "#{kubernetes_test.kubernetes_cluster.version}.1"}}},
        ],
      }
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(nodes_json), 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -o json").and_return(response)

      response_raw = Net::SSH::Connection::Session::StringWithExitstatus.new("nodes_raw", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes").and_return(response_raw)

      expect { kubernetes_test.wait_for_upgrade }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("Not all 1 nodes upgraded to #{kubernetes_test.kubernetes_cluster.version}:\nnodes_raw")
    end

    it "hops to verify_data_after_upgrade when all cluster nodes are upgraded" do
      kubernetes_test.kubernetes_cluster.strand.update(label: "wait")
      Strand.where(id: kubernetes_test.kubernetes_cluster.nodepools_dataset.select(:id)).update(label: "wait")
      kubernetes_test.kubernetes_cluster.update(kubeconfig: "stored")

      nodes_json = {
        "items" => [{"status" => {"nodeInfo" => {"kubeletVersion" => "#{kubernetes_test.kubernetes_cluster.version}.0"}}}] * 2,
      }
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(nodes_json), 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -o json").and_return(response)

      expect { kubernetes_test.wait_for_upgrade }.to hop("verify_data_after_upgrade")
    end
  end

  describe "#verify_data_after_upgrade" do
    before do
      refresh_frame(kubernetes_test, new_values: {"read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
    end

    it "naps until pod is running" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get events --field-selector involvedObject.name=ubuntu-statefulset-0 --sort-by=.lastTimestamp")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv,pvc")
      expect { kubernetes_test.verify_data_after_upgrade }.to nap(5)
    end

    it "validates every file hash and hops to destroy_kubernetes when data survived" do
      expect(kubernetes_test).to receive(:pod_status).and_return("Running")
      (1..3).each do |i|
        response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      end
      expect { kubernetes_test.verify_data_after_upgrade }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to be_nil
    end

    it "sets fail_message and hops to destroy_kubernetes when a file did not survive" do
      expect(kubernetes_test).to receive(:pod_status).and_return("Running")
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("garbage", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-1\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      expect { kubernetes_test.verify_data_after_upgrade }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("data hash changed after upgrade for random-data-1, expected: hash1, got: garbage")
    end
  end

  describe "#destroy_kubernetes" do
    it "increments destroy and hops to finish" do
      expect { kubernetes_test.destroy_kubernetes }.to hop("finish")
      expect(kubernetes_test.kubernetes_cluster.destroy_set?).to be true
    end
  end

  describe "#finish" do
    it "naps if kubernetes cluster is not destroyed yet" do
      expect { kubernetes_test.finish }.to nap(5)
    end

    context "when the kubernetes cluster is destroyed" do
      let(:strand_stack) { [{"kubernetes_test_project_id" => kubernetes_test_project.id, "fail_message" => fail_message}] }
      let(:fail_message) { nil }

      it "destroys test project and exits successfully" do
        expect { kubernetes_test.finish }.to exit({"msg" => "KubernetesUpgrade tests are finished!"})
          .and change { Project.where(id: kubernetes_test_project.id).count }.from(1).to(0)
      end

      context "with a fail message" do
        let(:fail_message) { "Test failed" }

        it "destroys test project and fails the test" do
          expect { kubernetes_test.finish }.to hop("failed")
            .and change { Project.where(id: kubernetes_test_project.id).count }.from(1).to(0)
          expect(kubernetes_test.strand.exitval).to eq({"msg" => "Test failed"})
        end
      end
    end
  end

  describe "#failed" do
    it "naps" do
      expect { kubernetes_test.failed }.to nap(15)
    end
  end
end
