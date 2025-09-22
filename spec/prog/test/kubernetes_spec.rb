# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::Kubernetes do
  subject(:kubernetes_test) {
    described_class.new(Strand.new(prog: "Test::Kubernetes", label: "start", stack: [{}]))
  }

  let(:kubernetes_service_project_id) { "546a1ed8-53e5-86d2-966c-fb782d2ae3aa" }
  let(:kubernetes_test_project) { Project.create(name: "Kubernetes-Test-Project", feature_flags: {"install_csi" => true}) }
  let(:kubernetes_service_project) { Project.create_with_id(kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources") }
  let(:private_subnet) { PrivateSubnet.create(name: "test-subnet", location_id: Location::HETZNER_FSN1_ID, project_id: kubernetes_test_project.id, net6: "fe80::/64", net4: "192.168.0.0/24") }
  let(:kubernetes_cluster) {
    kc = KubernetesCluster.create(name: "test-cluster", version: Option.kubernetes_versions.last, cp_node_count: 1, location_id: Location::HETZNER_FSN1_ID, target_node_size: "standard-2", target_node_storage_size_gib: 100, project_id: kubernetes_test_project.id, private_subnet_id: private_subnet.id)
    KubernetesNodepool.create(name: "test-cluster-np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
    kc
  }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(kubernetes_service_project.id)
  end

  describe ".assemble" do
    it "creates test and service projects and a strand" do
      expect(Config).to receive(:kubernetes_service_project_id).and_return("4fd01c1a-f022-43e8-bd3d-6dbe214df6ed")
      st = described_class.assemble
      expect(st.stack.first["kubernetes_test_project_id"]).not_to be_empty
    end
  end

  describe "#start" do
    it "assembles kubernetes cluster and hops to update_loadbalancer_hostname" do
      expect(kubernetes_test).to receive(:frame).and_return({"kubernetes_test_project_id" => kubernetes_test_project.id})
      expect(kubernetes_test).to receive(:update_stack)

      expect { kubernetes_test.start }.to hop("update_loadbalancer_hostname")

      expect(KubernetesCluster.count).to eq(1)
      expect(KubernetesNodepool.count).to eq(1)
    end
  end

  describe "#update_loadbalancer_hostname" do
    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
    end

    it "naps if loadbalancer is not ready yet" do
      expect { kubernetes_test.update_loadbalancer_hostname }.to nap(5)
    end

    it "updates custom hostname and hops to update_all_nodes_hosts_entries" do
      lb = LoadBalancer.create(private_subnet_id: private_subnet.id, name: "api-lb", health_check_endpoint: "/healthz", project_id: kubernetes_test_project.id)
      kubernetes_cluster.update(api_server_lb_id: lb.id)

      expect { kubernetes_test.update_loadbalancer_hostname }.to hop("update_all_nodes_hosts_entries")
      expect(lb.reload.custom_hostname).to eq("k8s-e2e-test.ubicloud.test")
    end
  end

  describe "#update_all_nodes_hosts_entries" do
    let(:cp_sshable) { instance_double(Sshable) }
    let(:worker_sshable) { instance_double(Sshable) }

    before do
      kubernetes_test.strand.update(label: "update_all_nodes_hosts_entries")
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      KubernetesNode.create(vm_id: create_vm(name: "cp-node").id, kubernetes_cluster_id: kubernetes_cluster.id)
      KubernetesNode.create(vm_id: create_vm(name: "wo-node").id, kubernetes_cluster_id: kubernetes_cluster.id, kubernetes_nodepool_id: kubernetes_cluster.nodepools.first.id)
      lb = LoadBalancer.create(private_subnet_id: private_subnet.id, name: "api-lb", health_check_endpoint: "/healthz", project_id: kubernetes_test_project.id)
      kubernetes_cluster.update(api_server_lb_id: lb.id)
    end

    it "naps if the first vm is not ready" do
      expect(kubernetes_test).to receive(:vm_ready?).with(kubernetes_cluster.nodes.first.vm).and_return(false)
      expect { kubernetes_test.update_all_nodes_hosts_entries }.to nap(5)
    end

    it "ensures the host entires on the first cp vm and proceeds to next which makes it nap" do
      cp_node = kubernetes_cluster.nodes.first
      expect(kubernetes_test).to receive(:vm_ready?).with(cp_node.vm).and_return(true)
      expect(kubernetes_test).to receive(:ensure_hosts_entry).with(cp_node.sshable, kubernetes_cluster.api_server_lb.hostname)
      expect(kubernetes_test).to receive(:vm_ready?).with(kubernetes_cluster.nodepools.first.nodes.first.vm).and_return(false)
      expect { kubernetes_test.update_all_nodes_hosts_entries }.to nap(5)
    end

    it "ensures the host entires on the first worker vm and proceeds to wait_for_kubernetes_bootstrap" do
      cp_node = kubernetes_cluster.nodes.first
      worker_node = kubernetes_cluster.nodepools.first.nodes.first
      hostname = kubernetes_cluster.api_server_lb.hostname
      expect(kubernetes_test).to receive(:vm_ready?).with(cp_node.vm).and_return(true)
      expect(kubernetes_test).to receive(:ensure_hosts_entry).with(cp_node.sshable, hostname)
      expect(kubernetes_test).to receive(:vm_ready?).with(worker_node.vm).and_return(true)
      expect(kubernetes_test).to receive(:ensure_hosts_entry).with(worker_node.sshable, hostname)
      expect { kubernetes_test.update_all_nodes_hosts_entries }.to hop("wait_for_kubernetes_bootstrap")
    end

    it "tries to ensure host entry on a not-ready worker node while the first cp node is taken care of" do
      kubernetes_test.set_node_entries_status(kubernetes_cluster.nodes.first.name)
      expect(kubernetes_test).to receive(:vm_ready?).with(kubernetes_cluster.nodepools.first.nodes.first.vm).and_return(false)
      expect { kubernetes_test.update_all_nodes_hosts_entries }.to nap(5)
    end

    it "ensures the host entires on the first cp node but naps because worker vm is not created yet" do
      cp_node = kubernetes_cluster.nodes.first
      kubernetes_cluster.nodepools.first.nodes.first.destroy
      kubernetes_cluster.reload
      hostname = kubernetes_cluster.api_server_lb.hostname
      expect(kubernetes_test).to receive(:vm_ready?).with(cp_node.vm).and_return(true)
      expect(kubernetes_test).to receive(:ensure_hosts_entry).with(cp_node.sshable, hostname)
      expect { kubernetes_test.update_all_nodes_hosts_entries }.to nap(10)
    end
  end

  describe "#wait_for_kubernetes_bootstrap" do
    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
    end

    it "hops to test_nodes if cluster is ready" do
      expect(kubernetes_cluster).to receive(:strand).and_return(instance_double(Strand, label: "wait"))

      expect { kubernetes_test.wait_for_kubernetes_bootstrap }.to hop("test_nodes")
    end

    it "naps if cluster is not ready" do
      expect(kubernetes_cluster).to receive(:strand).at_least(:once).and_return(instance_double(Strand, label: "creating"))

      expect { kubernetes_test.wait_for_kubernetes_bootstrap }.to nap(10)
    end
  end

  describe "#test_nodes" do
    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
    end

    it "succeeds and hops to destroy_kubernetes" do
      KubernetesNode.create(vm_id: create_vm(name: "kcz70f4yk68e0ne5n6s938pmb2-ut4i8").id, kubernetes_cluster_id: kubernetes_cluster.id)
      KubernetesNode.create(vm_id: create_vm(name: "kngp6bg8qmx61gd46vk8cvdv6m-d2h94").id, kubernetes_cluster_id: kubernetes_cluster.id, kubernetes_nodepool_id: kubernetes_cluster.nodepools.first.id)

      client = instance_double(Kubernetes::Client)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
      expect(client).to receive(:kubectl).with("get nodes").and_return("NAME                               STATUS   ROLES           AGE     VERSION\nkcz70f4yk68e0ne5n6s938pmb2-ut4i8   Ready    control-plane   7m47s   v1.34.0\nkngp6bg8qmx61gd46vk8cvdv6m-d2h94   Ready    <none>          3m48s   v1.34.0")

      expect { kubernetes_test.test_nodes }.to hop("test_csi")
    end

    it "fails and hops to destroy_kubernetes with fail message" do
      client = instance_double(Kubernetes::Client)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
      expect(client).to receive(:kubectl).with("get nodes").and_raise("cluster issue")
      expect(kubernetes_test).to receive(:update_stack).with({"fail_message" => "Failed to run test kubectl command: cluster issue"})

      expect { kubernetes_test.test_nodes }.to hop("destroy_kubernetes")
    end

    it "fails if all nodes are not found and hops to destroy_kubernetes with fail message" do
      KubernetesNode.create(vm_id: create_vm(name: "kcz70f4yk68e0ne5n6s938pmb2-ut4i8").id, kubernetes_cluster_id: kubernetes_cluster.id)
      KubernetesNode.create(vm_id: create_vm(name: "kngp6bg8qmx61gd46vk8cvdv6m-d2h94").id, kubernetes_cluster_id: kubernetes_cluster.id, kubernetes_nodepool_id: kubernetes_cluster.nodepools.first.id)

      client = instance_double(Kubernetes::Client)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
      expect(client).to receive(:kubectl).with("get nodes").and_return("NAME                               STATUS   ROLES           AGE     VERSION\nkcz70f4yk68e0ne5n6s938pmb2-ut4i8   Ready    control-plane   7m47s   v1.34.0\n")

      expect(kubernetes_test).to receive(:update_stack).with({"fail_message" => "node kngp6bg8qmx61gd46vk8cvdv6m-d2h94 not found in cluster"})

      expect { kubernetes_test.test_nodes }.to hop("destroy_kubernetes")
    end
  end

  describe "#test_csi" do
    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
    end

    it "creates a statefulset for the following tests" do
      sshable = instance_double(Sshable)
      expect(kubernetes_cluster).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:cmd).with("sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -", stdin: /apiVersion: apps/)
      expect { kubernetes_test.test_csi }.to hop("wait_for_statefulset")
    end
  end

  describe "#wait_for_statefulset" do
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
    end

    it "waits for the stateful pod to become running" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").and_return("Running")
      expect { kubernetes_test.wait_for_statefulset }.to hop("test_lsblk")
    end

    it "naps if pod is not running yet" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 -ojsonpath={.status.phase}").and_return("ContainerCreating")
      expect { kubernetes_test.wait_for_statefulset }.to nap(5)
    end
  end

  describe "#test_lsblk" do
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
    end

    it "fails if the expected mount does not appear in lsblk output" do
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- lsblk").and_return("no-data")
      expect(kubernetes_test).to receive(:update_stack).with({"fail_message" => "No /etc/data mount found in lsblk output"})
      expect { kubernetes_test.test_lsblk }.to hop("destroy_kubernetes")
    end

    it "fails if expected mount is not found for data volume" do
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- lsblk").and_return("NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS\nvda 252:0 0 40G 0 disk\n|-vda1 252:1 0 39.9G 0 part /etc/resolv.conf\n| /etc/hosts\n| /etc/data")
      expect(kubernetes_test).to receive(:update_stack).with({"fail_message" => "/etc/data is mounted incorrectly: | /etc/data"})
      expect { kubernetes_test.test_lsblk }.to hop("destroy_kubernetes")
    end

    it "hops to the next test if lsblk output is ok" do
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- lsblk").and_return("NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS\nloop3 7:3 0 1G 0 loop /etc/data\nvda 252:0 0 40G 0 disk\n|-vda1 252:1 0 39.9G 0 part /etc/resolv.conf\n| /etc/hosts\n|-vda14 252:14 0 4M 0 part")
      expect { kubernetes_test.test_lsblk }.to hop("test_data_write")
    end
  end

  describe "#test_data_write" do
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      expect(kubernetes_cluster).to receive(:client).and_return(client).twice
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- sh -c \"head -c 200M /dev/urandom | tee /etc/data/random-data | sha256sum | awk '{print \\$1}'\"").and_return("hash")
    end

    it "writes data and validates the file hash and is ok" do
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- sh -c \"sha256sum /etc/data/random-data | awk '{print \\$1}'\"").and_return("hash")
      expect(kubernetes_test).to receive(:update_stack).with({"read_hash" => "hash"})
      expect { kubernetes_test.test_data_write }.to hop("test_pod_data_migration")
    end

    it "writes data and validates the file hash and is not ok" do
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- sh -c \"sha256sum /etc/data/random-data | awk '{print \\$1}'\"").and_return("wrong_hash")
      expect(kubernetes_test).to receive(:update_stack).with({"fail_message" => "wrong read hash, expected: hash, got: wrong_hash"})
      expect { kubernetes_test.test_data_write }.to hop("destroy_kubernetes")
    end
  end

  describe "#test_pod_data_migration" do
    before do
      nodepool = kubernetes_cluster.nodepools.first
      nodepool.update(node_count: 2)
      KubernetesNode.create(vm_id: create_vm(name: "cp-node").id, kubernetes_cluster_id: kubernetes_cluster.id)
      KubernetesNode.create(vm_id: create_vm(name: "w1-node").id, kubernetes_cluster_id: kubernetes_cluster.id, kubernetes_nodepool_id: nodepool.id)
      KubernetesNode.create(vm_id: create_vm(name: "w2-node").id, kubernetes_cluster_id: kubernetes_cluster.id, kubernetes_nodepool_id: nodepool.id)
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
    end

    it "cordons the node, deletes the pod and hops to verify_data_after_migration" do
      client = instance_double(Kubernetes::Client)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return("w1-node")
      expect(client).to receive(:kubectl).with("cordon w1-node")
      expect(client).to receive(:kubectl).with("uncordon w2-node")
      expect(client).to receive(:kubectl).with("delete pod ubuntu-statefulset-0 --wait=false")
      expect { kubernetes_test.test_pod_data_migration }.to hop("verify_data_after_migration")
    end
  end

  describe "#verify_data_after_migration" do
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      kubernetes_test.update_stack({"migration_number" => 0, "read_hash" => "hash"})
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      expect(kubernetes_cluster).to receive(:client).and_return(client).at_least(:once)
    end

    it "naps until the pod is running" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return("ContainerCreating")
      expect { kubernetes_test.verify_data_after_migration }.to nap(5)
    end

    it "checks the data hash after migration and hash is correct but goes for another round of migration" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return("Running")
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- sh -c \"sha256sum /etc/data/random-data | awk '{print \\$1}'\"").and_return("hash")
      expect(kubernetes_test).to receive(:increment_migration_number)
      expect { kubernetes_test.verify_data_after_migration }.to hop("test_pod_data_migration")
    end

    it "checks the data hash after migration and hash is correct and is done with migrations, hops to test_normal_pod_restart" do
      kubernetes_test.update_stack({"migration_number" => Prog::Test::Kubernetes::MIGRATION_TRIES})
      expect(kubernetes_test).to receive(:pod_status).and_return("Running")
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- sh -c \"sha256sum /etc/data/random-data | awk '{print \\$1}'\"").and_return("hash")
      expect { kubernetes_test.verify_data_after_migration }.to hop("test_normal_pod_restart")
    end

    it "checks the data hash after migration and hash is not correct" do
      expect(kubernetes_test).to receive(:pod_status).and_return("Running")
      expect(client).to receive(:kubectl).with("exec -t ubuntu-statefulset-0 -- sh -c \"sha256sum /etc/data/random-data | awk '{print \\$1}'\"").and_return("wronghash")
      expect(kubernetes_test).to receive(:update_stack).with({"fail_message" => "data hash changed after migration, expected: hash, got: wronghash"})

      expect { kubernetes_test.verify_data_after_migration }.to hop("destroy_kubernetes")
    end
  end

  describe "#test_normal_pod_restart" do
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      expect(kubernetes_cluster).to receive(:client).and_return(client).at_least(:once)
    end

    it "saves the current node and deletes the pod and hops to verify_normal_pod_restart" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return("nodename")
      expect(kubernetes_test).to receive(:update_stack).with({"normal_pod_restart_test_node" => "nodename"})
      expect(client).to receive(:kubectl).with("delete pod ubuntu-statefulset-0 --wait=false")
      expect { kubernetes_test.test_normal_pod_restart }.to hop("verify_normal_pod_restart")
    end
  end

  describe "#verify_normal_pod_restart" do
    let(:client) { instance_double(Kubernetes::Client) }

    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      expect(kubernetes_cluster).to receive(:client).and_return(client).at_least(:once)
    end

    it "waits until pod is runnning" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return("ContainerCreating")
      expect { kubernetes_test.verify_normal_pod_restart }.to nap(5)
    end

    it "verifies mount and hops to destroy kubernetes" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return("Running")
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return("nodename")
      expect(kubernetes_test.strand).to receive(:stack).and_return([{"normal_pod_restart_test_node" => "nodename"}])
      expect(kubernetes_test).to receive(:verify_mount)
      expect { kubernetes_test.verify_normal_pod_restart }.to hop("destroy_kubernetes")
    end

    it "finds a mismatch in node name" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return("Running")
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return("othernode")
      expect(kubernetes_test.strand).to receive(:stack).and_return([{"normal_pod_restart_test_node" => "nodename"}])
      expect(kubernetes_test).to receive(:update_stack).with({"fail_message" => "unexpected pod node change after restart, expected: nodename, got: othernode"})
      expect { kubernetes_test.verify_normal_pod_restart }.to hop("destroy_kubernetes")
    end

    it "fails when verifying the mount" do
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 | grep -v NAME | awk '{print $3}'").and_return("Running")
      expect(client).to receive(:kubectl).with("get pods ubuntu-statefulset-0 -ojsonpath={.spec.nodeName}").and_return("nodename")
      expect(kubernetes_test.strand).to receive(:stack).and_return([{"normal_pod_restart_test_node" => "nodename"}])
      expect(kubernetes_test).to receive(:verify_mount).and_raise("some error")
      expect(kubernetes_test).to receive(:update_stack).with({"fail_message" => "some error"})
      expect { kubernetes_test.verify_normal_pod_restart }.to hop("destroy_kubernetes")
    end
  end

  describe "#destroy_kubernetes" do
    it "increments destroy and hops to destroy" do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      expect(kubernetes_cluster).to receive(:incr_destroy)

      expect { kubernetes_test.destroy_kubernetes }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "naps if kubernetes cluster is not destroyed yet" do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster)
      expect { kubernetes_test.destroy }.to nap(5)
    end

    it "destroys test project and exits successfully" do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(nil)
      expect(kubernetes_test).to receive(:kubernetes_test_project).and_return(kubernetes_test_project)
      expect(kubernetes_test_project).to receive(:destroy)
      expect(kubernetes_test).to receive(:frame).and_return({}).twice

      expect { kubernetes_test.destroy }.to exit({"msg" => "Kubernetes tests are finished!"})
    end

    it "destroys test project and fails if there is a fail message" do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(nil)
      expect(kubernetes_test).to receive(:kubernetes_test_project).and_return(kubernetes_test_project)
      expect(kubernetes_test_project).to receive(:destroy)
      expect(kubernetes_test).to receive(:frame).and_return({"fail_message" => "Test failed"}).thrice
      expect(kubernetes_test).to receive(:fail_test).with("Test failed")

      expect { kubernetes_test.destroy }.to exit({"msg" => "Kubernetes tests are finished!"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { kubernetes_test.failed }.to nap(15)
    end
  end

  describe "#ensure_hosts_entry" do
    let(:sshable) { instance_double(Sshable) }
    let(:api_hostname) { "api.example.com" }

    before do
      expect(kubernetes_test).to receive(:kubernetes_cluster).and_return(kubernetes_cluster).at_least(:once)
      sshable = instance_double(Sshable, host: "first-api-server-ip")
      expect(kubernetes_cluster).to receive(:sshable).and_return(sshable)
    end

    it "adds host entry if not present" do
      expect(sshable).to receive(:cmd).with("cat /etc/hosts").and_return("127.0.0.1 localhost")
      expect(sshable).to receive(:cmd).with("echo first-api-server-ip\\ api.example.com | sudo tee -a /etc/hosts > /dev/null")

      kubernetes_test.ensure_hosts_entry(sshable, api_hostname)
    end

    it "does not add host entry if already present" do
      expect(sshable).to receive(:cmd).with("cat /etc/hosts").and_return("127.0.0.1 localhost\nfirst-api-server-ip api.example.com")
      expect(sshable).not_to receive(:cmd).with(/echo/)

      kubernetes_test.ensure_hosts_entry(sshable, api_hostname)
    end
  end

  describe "#vm_ready?" do
    it "returns early if vm is nil" do
      expect(kubernetes_test.vm_ready?(nil)).to be false
    end

    it "returns false if vm's sshable is not ready" do
      vm = create_vm
      sshable = instance_double(Sshable)
      expect(vm).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:cmd).with("uptime").and_raise("some error")
      expect(kubernetes_test.vm_ready?(vm)).to be false
    end

    it "returns true if vm's sshable is ready" do
      vm = create_vm
      sshable = instance_double(Sshable)
      expect(vm).to receive(:sshable).and_return(sshable)
      expect(sshable).to receive(:cmd).with("uptime").and_return("up")
      expect(kubernetes_test.vm_ready?(vm)).to be true
    end
  end

  describe "#kubernetes_test_project" do
    it "returns the test project" do
      expect(kubernetes_test).to receive(:frame).and_return({"kubernetes_test_project_id" => kubernetes_test_project.id})
      expect(kubernetes_test.kubernetes_test_project).to eq(kubernetes_test_project)
    end
  end

  describe "#kubernetes_cluster" do
    it "returns the kubernetes cluster" do
      expect(kubernetes_test).to receive(:frame).and_return({"kubernetes_cluster_id" => kubernetes_cluster.id})
      expect(kubernetes_test.kubernetes_cluster).to eq(kubernetes_cluster)
    end
  end

  describe "#node_host_entries_set?" do
    it "returns false when node entries are not set" do
      st = instance_double(Strand, stack: [
        {
          "kubernetes_service_project_id" => "uuid"
        }
      ])
      expect(kubernetes_test).to receive(:strand).and_return(st)
      expect(kubernetes_test.node_host_entries_set?("non-existing-node")).to be false
    end

    it "returns true when node entries are set" do
      st = instance_double(Strand, stack: [
        {
          "kubernetes_service_project_id" => "uuid",
          "nodes_status" => {
            "existing-node" => true
          }
        }
      ])
      expect(kubernetes_test).to receive(:strand).and_return(st)
      expect(kubernetes_test.node_host_entries_set?("existing-node")).to be true
    end
  end

  describe "#set_node_entries_status" do
    it "sets the node entires status" do
      st = Strand.new(prog: "Prog::Test::Kubernetes", label: "start", stack: [{"kubernetes_service_project_id" => "uuid"}])
      expect(kubernetes_test).to receive(:strand).and_return(st)
      expect(kubernetes_test).to receive(:update_stack).with({
        "kubernetes_service_project_id" => "uuid",
        "nodes_status" => {
          "somenode" => true
        }
      })
      kubernetes_test.set_node_entries_status("somenode")
    end
  end

  describe "#increment_migration_number" do
    it "increments the migration number" do
      kubernetes_test.update_stack({"migration_number" => 0})
      kubernetes_test.increment_migration_number
      expect(kubernetes_test.migration_number).to eq(1)
    end
  end
end
