# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::Kubernetes do
  subject(:kubernetes_test) {
    described_class.new(Strand.new(prog: "Test::Kubernetes", label: "start", stack: strand_stack))
  }

  let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id}] }

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
    kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "test-cluster-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
    Prog::Kubernetes::KubernetesNodeNexus.assemble(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "cp-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-4", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: Option.selectable_kubernetes_versions.first, private_subnet_id: kc.private_subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id)
    Prog::Kubernetes::KubernetesNodeNexus.assemble(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "w1-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-4", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: Option.selectable_kubernetes_versions.first, private_subnet_id: kc.private_subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
    Prog::Kubernetes::KubernetesNodeNexus.assemble(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "w2-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-4", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: Option.selectable_kubernetes_versions.first, private_subnet_id: kc.private_subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
    kc
  }
  let(:sshable) { kubernetes_test.kubernetes_cluster.sshable }
  let(:cp_node) { kubernetes_test.kubernetes_cluster.nodes.first }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(kubernetes_service_project.id)
    if (kc = kubernetes_test.kubernetes_cluster)
      allow(kc.sshable).to receive(:connect).and_return(session)
    end
  end

  describe ".assemble" do
    let(:strand_stack) { [{}] }

    it "creates test and service projects and a strand" do
      expect(Config).to receive(:kubernetes_service_project_id).at_least(:once).and_return("4fd01c1a-f022-43e8-bd3d-6dbe214df6ed")
      described_class.assemble
      expect(Project["4fd01c1a-f022-43e8-bd3d-6dbe214df6ed"]).not_to be_nil
      expect(Project.where(name: "Kubernetes-Test-Project").count).to eq(1)
    end

    it "reuses existing service project if it already exists" do
      project_count = Project.count
      described_class.assemble
      # +1 for the test project only; service project is reused
      expect(Project.count).to eq(project_count + 1)
    end
  end

  describe "#start" do
    let(:strand_stack) { [{"kubernetes_test_project_id" => kubernetes_test_project.id}] }

    it "assembles kubernetes cluster and hops to wait_for_kubernetes_bootstrap" do
      expect { kubernetes_test.start }.to hop("wait_for_kubernetes_bootstrap")
      expect(kubernetes_test.strand.stack[0]["kubernetes_cluster_id"]).to eq KubernetesCluster.get(:id)

      expect(KubernetesCluster.count).to eq(1)
      expect(KubernetesNodepool.count).to eq(1)
    end
  end

  describe "#wait_for_kubernetes_bootstrap" do
    it "hops to trigger_renew_certs if cluster is ready" do
      kubernetes_cluster.strand.update(label: "wait")
      expect { kubernetes_test.wait_for_kubernetes_bootstrap }.to hop("trigger_renew_certs")
    end

    it "naps if cluster is not ready" do
      expect { kubernetes_test.wait_for_kubernetes_bootstrap }.to nap(10)
    end
  end

  describe "#trigger_renew_certs" do
    it "records the current cert expiry, triggers renewal on the CP node and wakes its strand" do
      expect(cp_node.sshable).to receive(:_cmd).with("sudo openssl x509 -enddate -noout -in /etc/kubernetes/pki/apiserver.crt").and_return("notAfter=#{(Time.now + 365 * 24 * 60 * 60).utc.strftime("%b %e %H:%M:%S %Y")} GMT\n")
      expect { kubernetes_test.trigger_renew_certs }.to hop("wait_for_renew_certs")
      expect(cp_node.reload.renew_certs_set?).to be true
      expect(kubernetes_test.strand.stack.first["cert_expire_at_before_renew"]).not_to be_nil
    end
  end

  describe "#wait_for_renew_certs" do
    let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id, "cert_expire_at_before_renew" => (Time.now + 365 * 24 * 60 * 60).to_s}] }

    it "naps while the CP node is still renewing its certs" do
      cp_node.update(state: "renewing_certs")
      cp_node.strand.update(label: "renew_certs")
      expect { kubernetes_test.wait_for_renew_certs }.to nap(10)
    end

    it "naps when the renewal flow finished but the cert expiry has not advanced" do
      cp_node.strand.update(label: "wait")
      expect(cp_node.sshable).to receive(:_cmd).with("sudo openssl x509 -enddate -noout -in /etc/kubernetes/pki/apiserver.crt").and_return("notAfter=#{(Time.now + 365 * 24 * 60 * 60).utc.strftime("%b %e %H:%M:%S %Y")} GMT\n")
      expect { kubernetes_test.wait_for_renew_certs }.to nap(10)
    end

    it "hops to test_nodes once the renewal flow finished and the cert expiry has advanced" do
      cp_node.strand.update(label: "wait")
      expect(cp_node.sshable).to receive(:_cmd).with("sudo openssl x509 -enddate -noout -in /etc/kubernetes/pki/apiserver.crt").and_return("notAfter=#{(Time.now + 400 * 24 * 60 * 60).utc.strftime("%b %e %H:%M:%S %Y")} GMT\n")
      expect { kubernetes_test.wait_for_renew_certs }.to hop("test_nodes")
    end
  end

  describe "#test_nodes" do
    it "succeeds and hops to test_csi" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("NAME      STATUS   ROLES           AGE     VERSION\ncp-node   Ready    control-plane   7m47s   v1.34.0\nw1-node   Ready    control-plane   7m47s   v1.34.0\nw2-node   Ready    control-plane   7m47s   v1.34.0\n", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes").and_return(response)

      expect { kubernetes_test.test_nodes }.to hop("test_csi")
    end

    it "fails and hops to destroy_kubernetes with fail message" do
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes").and_raise("cluster issue")

      expect { kubernetes_test.test_nodes }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack[0]["fail_message"]).to eq "Failed to run test kubectl command: cluster issue"
    end

    it "fails if all nodes are not found and hops to destroy_kubernetes with fail message" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("NAME      STATUS   ROLES           AGE     VERSION\ncp-node   Ready    control-plane   7m47s   v1.34.0\nw2-node   Ready    control-plane   7m47s   v1.34.0\n", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes").and_return(response)

      expect { kubernetes_test.test_nodes }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack[0]["fail_message"]).to eq "node w1-node not found in cluster"
    end
  end

  describe "#test_csi" do
    it "creates a statefulset for the following tests" do
      expect(sshable).to receive(:_cmd).with("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -", stdin: /apiVersion: apps/)
      expect { kubernetes_test.test_csi }.to hop("wait_for_statefulset")
    end
  end

  describe "#wait_for_statefulset" do
    it "waits for the stateful pod to become running" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("Running", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").and_return(response)
      expect { kubernetes_test.wait_for_statefulset }.to hop("test_lsblk")
    end

    it "naps if pod is not running yet" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").and_return(response)
      expect { kubernetes_test.wait_for_statefulset }.to nap(5)
    end
  end

  describe "#test_lsblk" do
    it "fails if the expected mount does not appear in lsblk output" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("no-data", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- lsblk").and_return(response)
      expect { kubernetes_test.test_lsblk }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack[0]["fail_message"]).to eq "No /etc/data mount found in lsblk output"
    end

    it "fails if expected mount is not found for data volume" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS\nvda 252:0 0 40G 0 disk\n|-vda1 252:1 0 39.9G 0 part /etc/resolv.conf\n| /etc/hosts\n| /etc/data", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- lsblk").and_return(response)
      expect { kubernetes_test.test_lsblk }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack[0]["fail_message"]).to eq "/etc/data is mounted incorrectly: | /etc/data"
    end

    it "hops to test_data_write if lsblk output is ok" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS\nloop3 7:3 0 5G 0 loop /etc/data\nvda 252:0 0 40G 0 disk\n|-vda1 252:1 0 39.9G 0 part /etc/resolv.conf\n| /etc/hosts\n|-vda14 252:14 0 4M 0 part", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- lsblk").and_return(response)
      expect { kubernetes_test.test_lsblk }.to hop("test_data_write")
    end
  end

  describe "#test_data_write" do
    it "launches 3 parallel daemonized writes and hops to wait_data_write" do
      (1..3).each do |i|
        unit_name = "csi_data_write_#{i}"
        bash_cmd = "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf exec -t ubuntu-statefulset-0 -- sh -c \"head -c 300M /dev/urandom | tee /etc/data/random-data-#{i} | sha256sum | awk '{print \\$1}'\" > /dev/shm/#{unit_name}.hash"
        expected_cmd = "common/bin/daemonizer2 run #{unit_name} #{["bash", "-c", bash_cmd].shelljoin}"
        expect(sshable).to receive(:_cmd).with(expected_cmd, stdin: nil, log: true)
      end
      expect { kubernetes_test.test_data_write }.to hop("wait_data_write")
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

    it "hops to verify_data_write when all writes have succeeded" do
      (1..3).each do |i|
        expect(sshable).to receive(:d_check).with("csi_data_write_#{i}").and_return("Succeeded")
      end
      expect { kubernetes_test.wait_data_write }.to hop("verify_data_write")
    end
  end

  describe "#verify_data_write" do
    it "reads write hashes, validates all read hashes and hops to test_pod_data_migration" do
      (1..3).each do |i|
        expect(sshable).to receive(:_cmd).with("cat /dev/shm/csi_data_write_#{i}.hash").and_return("hash#{i}")
        read_response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(read_response)
        expect(sshable).to receive(:d_clean).with("csi_data_write_#{i}")
      end
      expect { kubernetes_test.verify_data_write }.to hop("test_pod_data_migration")
      expect(kubernetes_test.strand.stack[0]["read_hashes"]).to eq({"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"})
    end

    it "fails on the first file if write and read hashes don't match" do
      expect(sshable).to receive(:_cmd).with("cat /dev/shm/csi_data_write_1.hash").and_return("hash1")
      read_response = Net::SSH::Connection::Session::StringWithExitstatus.new("wrong_hash", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-1\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(read_response)
      expect(sshable).to receive(:d_clean).with("csi_data_write_1")
      expect { kubernetes_test.verify_data_write }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("wrong read hash for random-data-1, expected: hash1, got: wrong_hash")
    end
  end

  describe "#test_pod_data_migration" do
    it "cordons the node, deletes the pod and hops to verify_data_after_migration" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("w1-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(response)
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s cordon w1-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s uncordon w2-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s delete pod ubuntu-statefulset-0 --wait=false").and_return(response)
      expect { kubernetes_test.test_pod_data_migration }.to hop("verify_data_after_migration")
    end
  end

  describe "#verify_data_after_migration" do
    before do
      refresh_frame(kubernetes_test, new_values: {"migration_number" => 0, "read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
    end

    it "naps until the pod is running" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get events --field-selector involvedObject.name=ubuntu-statefulset-0 --sort-by=.lastTimestamp")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv,pvc")
      expect { kubernetes_test.verify_data_after_migration }.to nap(5)
    end

    it "checks all data hashes after migration and goes for another round" do
      expect(kubernetes_test).to receive(:pod_status).and_return("Running")
      (1..3).each do |i|
        response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      end
      expect { kubernetes_test.verify_data_after_migration }.to hop("test_pod_data_migration")
    end

    it "checks all data hashes and is done with migrations, hops to test_normal_pod_restart" do
      refresh_frame(kubernetes_test, new_values: {"migration_number" => Prog::Test::Kubernetes::MIGRATION_TRIES})
      expect(kubernetes_test).to receive(:pod_status).and_return("Running")
      (1..3).each do |i|
        response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      end
      expect { kubernetes_test.verify_data_after_migration }.to hop("test_normal_pod_restart")
    end
  end

  describe "#test_normal_pod_restart" do
    it "saves the current node and deletes the pod and hops to verify_normal_pod_restart" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("nodename", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(response)
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s delete pod ubuntu-statefulset-0 --wait=false").and_return(response)
      expect { kubernetes_test.test_normal_pod_restart }.to hop("verify_normal_pod_restart")
      expect(kubernetes_test.strand.stack[0]["normal_pod_restart_test_node"]).to eq "nodename"
    end
  end

  describe "#verify_normal_pod_restart" do
    it "waits until pod is runnning" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get events --field-selector involvedObject.name=ubuntu-statefulset-0 --sort-by=.lastTimestamp")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv,pvc")
      expect { kubernetes_test.verify_normal_pod_restart }.to nap(5)
    end

    it "verifies mount and hops to destroy kubernetes" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("Running", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("nodename", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(response)
      refresh_frame(kubernetes_test, new_values: {"normal_pod_restart_test_node" => "nodename"})
      expect(kubernetes_test).to receive(:verify_mount)
      expect { kubernetes_test.verify_normal_pod_restart }.to hop("test_rsync_retry")
    end

    it "finds a mismatch in node name" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("Running", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("othernode", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(response)
      refresh_frame(kubernetes_test, new_values: {"normal_pod_restart_test_node" => "nodename"})
      expect { kubernetes_test.verify_normal_pod_restart }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack[0]["fail_message"]).to eq "unexpected pod node change after restart, expected: nodename, got: othernode"
    end

    it "fails when verifying the mount" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("Running", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("nodename", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(response)
      refresh_frame(kubernetes_test, new_values: {"normal_pod_restart_test_node" => "nodename"})
      expect(kubernetes_test).to receive(:verify_mount).and_raise("some error")
      expect { kubernetes_test.verify_normal_pod_restart }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack[0]["fail_message"]).to eq "some error"
    end
  end

  describe "#test_rsync_retry" do
    it "uncordons nodes, cordons pod node, triggers migration and hops to kill_rsync_process" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s uncordon w1-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s uncordon w2-node").and_return(response)

      pod_node_response = Net::SSH::Connection::Session::StringWithExitstatus.new("w1-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(pod_node_response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s cordon w1-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s delete pod ubuntu-statefulset-0 --wait=false").and_return(response)

      expect { kubernetes_test.test_rsync_retry }.to hop("kill_rsync_process")
      expect(kubernetes_test.strand.stack.first["rsync_retry_source_node"]).to eq("w1-node")
    end
  end

  describe "#kill_rsync_process" do
    let(:target_node) {
      kubernetes_test.kubernetes_cluster.nodepools.first.nodes.find { |n| n.name == "w2-node" }
    }

    it "naps if pod is not yet scheduled" do
      pod_response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(pod_response)
      expect { kubernetes_test.kill_rsync_process }.to nap(1)
    end

    it "naps if rsync has not started yet" do
      pod_response = Net::SSH::Connection::Session::StringWithExitstatus.new("w2-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(pod_response)
      expect(target_node.sshable).to receive(:_cmd).with("pgrep rsync || true").and_return("")
      expect { kubernetes_test.kill_rsync_process }.to nap(1)
    end

    it "kills rsync and hops to verify_rsync_retry" do
      pod_response = Net::SSH::Connection::Session::StringWithExitstatus.new("w2-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(pod_response)
      expect(target_node.sshable).to receive(:_cmd).with("pgrep rsync || true").and_return("12345 rsync -az /var/lib/ubicsi/vol.img")
      expect(target_node.sshable).to receive(:_cmd).with("sudo pkill -9 rsync")
      expect { kubernetes_test.kill_rsync_process }.to hop("verify_rsync_retry")
    end
  end

  describe "#verify_rsync_retry" do
    it "naps until pod is running" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get events --field-selector involvedObject.name=ubuntu-statefulset-0 --sort-by=.lastTimestamp")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv,pvc")
      expect { kubernetes_test.verify_rsync_retry }.to nap(5)
    end

    it "verifies data hashes and hops to test_node_not_deleted_during_copy" do
      refresh_frame(kubernetes_test, new_values: {"read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
      expect(kubernetes_test).to receive(:pod_status).and_return("Running")
      (1..3).each do |i|
        response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      end
      expect { kubernetes_test.verify_rsync_retry }.to hop("test_chained_migration")
    end
  end

  describe "#test_chained_migration" do
    before do
      nodepool = kubernetes_cluster.nodepools.first
      nodepool.update(node_count: 3)
      Prog::Kubernetes::KubernetesNodeNexus.assemble(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "w3-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-4", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: Option.selectable_kubernetes_versions.first, private_subnet_id: kubernetes_cluster.private_subnet.id, enable_ip4: true, kubernetes_cluster_id: kubernetes_cluster.id, kubernetes_nodepool_id: nodepool.id)
    end

    it "uncordons all, cordons pod node, deletes pod and hops to cordon_chained_target" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s uncordon w1-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s uncordon w2-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s uncordon w3-node").and_return(response)

      pod_response = Net::SSH::Connection::Session::StringWithExitstatus.new("w1-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(pod_response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s cordon w1-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s delete pod ubuntu-statefulset-0 --wait=false").and_return(response)

      expect { kubernetes_test.test_chained_migration }.to hop("cordon_chained_target")
      expect(kubernetes_test.strand.stack.first["chained_migration_source_node"]).to eq("w1-node")
    end
  end

  describe "#cordon_chained_target" do
    let(:target_node) {
      kubernetes_test.kubernetes_cluster.nodepools.first.nodes.find { |n| n.name == "w2-node" }
    }

    before do
      refresh_frame(kubernetes_test, new_values: {"chained_migration_source_node" => "w1-node"})
    end

    it "naps if pod is not yet scheduled" do
      pod_response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(pod_response)
      expect { kubernetes_test.cordon_chained_target }.to nap(1)
    end

    it "naps if rsync has not started on target node" do
      pod_response = Net::SSH::Connection::Session::StringWithExitstatus.new("w2-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(pod_response)
      expect(target_node.sshable).to receive(:_cmd).with("pgrep rsync || true").and_return("")
      expect { kubernetes_test.cordon_chained_target }.to nap(1)
    end

    it "cordons the rsync target, deletes pod and hops to verify_chained_migration" do
      pod_response = Net::SSH::Connection::Session::StringWithExitstatus.new("w2-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(pod_response)
      expect(target_node.sshable).to receive(:_cmd).with("pgrep rsync || true").and_return("12345 rsync -az /var/lib/ubicsi/vol.img")
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s cordon w2-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s delete pod ubuntu-statefulset-0 --wait=false").and_return(response)
      expect { kubernetes_test.cordon_chained_target }.to hop("verify_chained_migration")
    end
  end

  describe "#verify_chained_migration" do
    it "naps until pod is running" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get events --field-selector involvedObject.name=ubuntu-statefulset-0 --sort-by=.lastTimestamp")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv,pvc")
      expect { kubernetes_test.verify_chained_migration }.to nap(5)
    end

    it "verifies data hashes and hops to test_node_not_deleted_during_copy" do
      refresh_frame(kubernetes_test, new_values: {"read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
      expect(kubernetes_test).to receive(:pod_status).and_return("Running")
      (1..3).each do |i|
        response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      end
      expect { kubernetes_test.verify_chained_migration }.to hop("test_node_not_deleted_during_copy")
    end
  end

  describe "#test_node_not_deleted_during_copy" do
    it "uncordons all nodes, retires the pod node and hops to verify_node_not_deleted_during_copy" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s uncordon w1-node").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s uncordon w2-node").and_return(response)

      response = Net::SSH::Connection::Session::StringWithExitstatus.new("w1-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return(response)

      pod_node = kubernetes_test.kubernetes_cluster.nodepools.first.nodes.find { |n| n.name == "w1-node" }

      expect { kubernetes_test.test_node_not_deleted_during_copy }.to hop("verify_node_not_deleted_during_copy")
      expect(kubernetes_test.strand.stack.first["drain_test_node_name"]).to eq("w1-node")
      expect(pod_node.reload.retire_set?).to be true
    end
  end

  describe "#verify_node_not_deleted_during_copy" do
    it "hops to verify_data_after_drain when node record is destroyed" do
      refresh_frame(kubernetes_test, new_values: {"drain_test_node_name" => "gone-node"})
      expect { kubernetes_test.verify_node_not_deleted_during_copy }.to hop("verify_data_after_drain")
    end

    it "naps when copy is pending and node still exists" do
      KubernetesNode.create(vm_id: create_vm(name: "w1-node").id, kubernetes_cluster_id: kubernetes_cluster.id)
      refresh_frame(kubernetes_test, new_values: {"drain_test_node_name" => "w1-node"})

      pv_list = {"items" => [{
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => "data"}},
        "spec" => {
          "persistentVolumeReclaimPolicy" => "Retain",
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["w1-node"]}]}]}},
        },
      }]}
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(pv_list), 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(response)

      get_node_response = Net::SSH::Connection::Session::StringWithExitstatus.new("w1-node", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get node w1-node").and_return(get_node_response)

      expect { kubernetes_test.verify_node_not_deleted_during_copy }.to nap(15)
    end

    it "fails when copy is pending but node is already removed" do
      KubernetesNode.create(vm_id: create_vm(name: "w1-node").id, kubernetes_cluster_id: kubernetes_cluster.id)
      refresh_frame(kubernetes_test, new_values: {"drain_test_node_name" => "w1-node"})

      pv_list = {"items" => [{
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => "data"}},
        "spec" => {
          "persistentVolumeReclaimPolicy" => "Retain",
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["w1-node"]}]}]}},
        },
      }]}
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(pv_list), 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(response)

      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get node w1-node").and_raise("not found")

      expect { kubernetes_test.verify_node_not_deleted_during_copy }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("Node w1-node was removed while CSI data copy was still in progress: not found")
    end

    it "naps when no copy is pending but node still exists" do
      KubernetesNode.create(vm_id: create_vm(name: "w1-node").id, kubernetes_cluster_id: kubernetes_cluster.id)
      refresh_frame(kubernetes_test, new_values: {"drain_test_node_name" => "w1-node"})

      pv_list = {"items" => []}
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(pv_list), 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(response)

      expect { kubernetes_test.verify_node_not_deleted_during_copy }.to nap(15)
    end
  end

  describe "#verify_data_after_drain" do
    it "naps until pod is running" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get events --field-selector involvedObject.name=ubuntu-statefulset-0 --sort-by=.lastTimestamp")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv,pvc")
      expect { kubernetes_test.verify_data_after_drain }.to nap(5)
    end

    it "verifies all data hashes and hops to test_reboot_nftables" do
      refresh_frame(kubernetes_test, new_values: {"read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("Running", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      (1..3).each do |i|
        response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      end
      expect { kubernetes_test.verify_data_after_drain }.to hop("test_reboot_nftables")
    end
  end

  describe "#test_reboot_nftables" do
    let(:node) { kubernetes_test.kubernetes_cluster.nodepools.first.nodes.first }
    let(:sshable) { node.sshable }

    it "captures nft rules, reboots the node, and hops to verify_reboot_nftables" do
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip nat postrouting").and_return("table ip nat { ... }")
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip6 pod_access ingress_egress_control").and_return("table ip6 pod_access { ... }")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reboot")
      expect { kubernetes_test.test_reboot_nftables }.to hop("verify_reboot_nftables")
      expect(kubernetes_test.strand.stack.first).to include("reboot_node_id" => node.id, "nat_rules_before_reboot" => "table ip nat { ... }", "pod_access_rules_before_reboot" => "table ip6 pod_access { ... }")
    end

    it "rescues SSH error during reboot and still hops" do
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip nat postrouting").and_return("table ip nat { ... }")
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip6 pod_access ingress_egress_control").and_return("table ip6 pod_access { ... }")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reboot").and_raise("connection closed")
      expect { kubernetes_test.test_reboot_nftables }.to hop("verify_reboot_nftables")
    end
  end

  describe "#verify_reboot_nftables" do
    let(:node) { kubernetes_test.kubernetes_cluster.nodepools.first.nodes.first }
    let(:sshable) { node.sshable }

    it "naps if vm is not ready yet" do
      refresh_frame(kubernetes_test, new_values: {
        "reboot_node_id" => node.id,
        "nat_rules_before_reboot" => "table ip nat { ... }",
        "pod_access_rules_before_reboot" => "table ip6 pod_access { ... }",
      })
      kubernetes_test.instance_variable_set(:@frame, nil)
      expect(sshable).to receive(:_cmd).with("uptime").and_raise("not ready")
      expect { kubernetes_test.verify_reboot_nftables }.to nap(5)
    end

    it "hops to test_upgrade when rules match" do
      refresh_frame(kubernetes_test, new_values: {
        "reboot_node_id" => node.id,
        "nat_rules_before_reboot" => "table ip nat { ... }",
        "pod_access_rules_before_reboot" => "table ip6 pod_access { ... }",
      })
      kubernetes_test.instance_variable_set(:@frame, nil)
      expect(sshable).to receive(:_cmd).with("uptime").and_return("up")
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip nat postrouting").and_return("table ip nat { ... }")
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip6 pod_access ingress_egress_control").and_return("table ip6 pod_access { ... }")
      expect { kubernetes_test.verify_reboot_nftables }.to hop("test_upgrade")
    end

    it "sets fail_message when ip nat rules changed" do
      refresh_frame(kubernetes_test, new_values: {
        "reboot_node_id" => node.id,
        "nat_rules_before_reboot" => "table ip nat { ... }",
        "pod_access_rules_before_reboot" => "table ip6 pod_access { ... }",
      })
      kubernetes_test.instance_variable_set(:@frame, nil)
      expect(sshable).to receive(:_cmd).with("uptime").and_return("up")
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip nat postrouting").and_return("different nat rules")
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip6 pod_access ingress_egress_control").and_return("table ip6 pod_access { ... }")
      expect { kubernetes_test.verify_reboot_nftables }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("ip nat rules changed after reboot")
    end

    it "sets fail_message when ip6 pod_access rules changed" do
      refresh_frame(kubernetes_test, new_values: {
        "reboot_node_id" => node.id,
        "nat_rules_before_reboot" => "table ip nat { ... }",
        "pod_access_rules_before_reboot" => "table ip6 pod_access { ... }",
      })
      kubernetes_test.instance_variable_set(:@frame, nil)
      expect(sshable).to receive(:_cmd).with("uptime").and_return("up")
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip nat postrouting").and_return("table ip nat { ... }")
      expect(sshable).to receive(:_cmd).with("sudo nft list chain ip6 pod_access ingress_egress_control").and_return("different pod_access rules")
      expect { kubernetes_test.verify_reboot_nftables }.to hop("test_upgrade")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("ip6 pod_access rules changed after reboot")
    end
  end

  describe "#test_upgrade" do
    it "fails if no upgrade candidate is available" do
      kubernetes_test.kubernetes_cluster.update(version: Option.selectable_kubernetes_versions.first)
      expect { kubernetes_test.test_upgrade }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("No upgrade candidate available")
    end

    it "updates version, increments uprades semaphores, and hops to wait_for_upgrade" do
      target_version = kubernetes_cluster.available_upgrade_version
      expect { kubernetes_test.test_upgrade }.to hop("wait_for_upgrade")

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

    it "fails if some nodes are not upgraded" do
      kubernetes_test.kubernetes_cluster.strand.update(label: "wait")
      Strand.where(id: kubernetes_test.kubernetes_cluster.nodepools_dataset.select(:id)).update(label: "wait")
      kubernetes_test.kubernetes_cluster.update(kubeconfig: "stored")

      nodes_json = {
        "items" => [
          {"status" => {"nodeInfo" => {"kubeletVersion" => "#{kubernetes_cluster.version}.1"}}},
          {"status" => {"nodeInfo" => {"kubeletVersion" => "v1.30.1"}}},
          {"status" => {"nodeInfo" => {"kubeletVersion" => "#{kubernetes_cluster.version}.1"}}},
        ],
      }
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(nodes_json), 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -o json").and_return(response)

      response_raw = Net::SSH::Connection::Session::StringWithExitstatus.new("nodes_raw", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes").and_return(response_raw)

      expect { kubernetes_test.wait_for_upgrade }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("Not all 3 nodes upgraded to #{kubernetes_cluster.version}:\nnodes_raw")
    end

    it "fails if node count is not 3" do
      kubernetes_test.kubernetes_cluster.strand.update(label: "wait")
      Strand.where(id: kubernetes_test.kubernetes_cluster.nodepools_dataset.select(:id)).update(label: "wait")
      kubernetes_test.kubernetes_cluster.update(kubeconfig: "stored")

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

    it "hops to verify_data_after_upgrade if all 3 nodes are upgraded correctly" do
      kubernetes_test.kubernetes_cluster.strand.update(label: "wait")
      Strand.where(id: kubernetes_test.kubernetes_cluster.nodepools_dataset.select(:id)).update(label: "wait")
      kubernetes_test.kubernetes_cluster.update(kubeconfig: "stored")

      nodes_json = {
        "items" => [{"status" => {"nodeInfo" => {"kubeletVersion" => "#{kubernetes_test.kubernetes_cluster.version}.0"}}}] * 3,
      }
      response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(nodes_json), 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -o json").and_return(response)

      expect { kubernetes_test.wait_for_upgrade }.to hop("verify_data_after_upgrade")
    end
  end

  describe "#verify_data_after_upgrade" do
    it "naps until pod is running" do
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("ContainerCreating", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get events --field-selector involvedObject.name=ubuntu-statefulset-0 --sort-by=.lastTimestamp")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv,pvc")
      expect { kubernetes_test.verify_data_after_upgrade }.to nap(5)
    end

    it "verifies all data hashes and hops to destroy_kubernetes" do
      refresh_frame(kubernetes_test, new_values: {"read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("Running", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      (1..3).each do |i|
        response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      end
      expect { kubernetes_test.verify_data_after_upgrade }.to hop("destroy_kubernetes")
    end

    it "sets fail_message and hops to destroy_kubernetes if a hash is wrong" do
      refresh_frame(kubernetes_test, new_values: {"read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("Running", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return(response)
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("corrupted_hash", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-1\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)

      expect { kubernetes_test.verify_data_after_upgrade }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq("data hash changed after upgrade for random-data-1, expected: hash1, got: corrupted_hash")
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
        expect { kubernetes_test.finish }.to exit({"msg" => "Kubernetes tests are finished!"})
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

  describe "#vm_ready?" do
    it "returns early if vm is nil" do
      expect(kubernetes_test.vm_ready?(nil)).to be false
    end

    it "returns false if vm's sshable is not ready" do
      vm = kubernetes_cluster.nodes.first.vm
      expect(vm.sshable).to receive(:_cmd).with("uptime").and_raise("some error")
      expect(kubernetes_test.vm_ready?(vm)).to be false
    end

    it "returns true if vm's sshable is ready" do
      vm = kubernetes_cluster.nodes.first.vm
      expect(vm.sshable).to receive(:_cmd).with("uptime").and_return("up")
      expect(kubernetes_test.vm_ready?(vm)).to be true
    end
  end

  describe "#kubernetes_test_project" do
    let(:strand_stack) { [{"kubernetes_test_project_id" => kubernetes_test_project.id}] }

    it "returns the test project" do
      expect(kubernetes_test.kubernetes_test_project).to eq(kubernetes_test_project)
    end
  end

  describe "#verify_data_hashes" do
    it "verifies all hashes match" do
      refresh_frame(kubernetes_test, new_values: {"read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
      (1..3).each do |i|
        response = Net::SSH::Connection::Session::StringWithExitstatus.new("hash#{i}", 0)
        expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-#{i}\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      end
      kubernetes_test.verify_data_hashes("migration")
    end

    it "sets fail_message when a hash does not match" do
      refresh_frame(kubernetes_test, new_values: {"read_hashes" => {"random-data-1" => "hash1", "random-data-2" => "hash2", "random-data-3" => "hash3"}})
      response = Net::SSH::Connection::Session::StringWithExitstatus.new("wronghash", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s exec -t ubuntu-statefulset-0 -- sh -c sha256sum\\ /etc/data/random-data-1\\ \\|\\ awk\\ \\'\\{print\\ \\$1\\}\\'").and_return(response)
      expect { kubernetes_test.verify_data_hashes("migration") }.to hop("destroy_kubernetes")
      expect(kubernetes_test.strand.stack[0]["fail_message"]).to eq "data hash changed after migration for random-data-1, expected: hash1, got: wronghash"
    end
  end
end
