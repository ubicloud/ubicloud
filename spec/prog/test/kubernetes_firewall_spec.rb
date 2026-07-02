# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::KubernetesFirewall do
  subject(:kubernetes_test) {
    described_class.new(Strand.new(prog: "Test::KubernetesFirewall", label: "start", stack: strand_stack))
  }

  let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id}] }

  let(:kubernetes_service_project_id) { "546a1ed8-53e5-86d2-966c-fb782d2ae3aa" }
  let(:kubernetes_test_project) { Project.create(name: "Kubernetes-Test-Project") }
  let(:kubernetes_service_project) { Project.create_with_id(kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources") }
  let(:session) { Net::SSH::Connection::Session.allocate }
  let(:kubernetes_cluster) {
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "test-cluster", version: Option.selectable_kubernetes_versions.last, location_id: Location::HETZNER_FSN1_ID,
      project_id: kubernetes_test_project.id, cp_node_count: 1, target_node_size: "standard-2").subject
    lb = LoadBalancer.create(private_subnet_id: kc.private_subnet.id, name: "api-lb", health_check_endpoint: "/healthz", project_id: kubernetes_test_project.id)
    kc.update(api_server_lb_id: lb.id)
    kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "test-cluster-np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
    Prog::Kubernetes::KubernetesNodeNexus.assemble(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "cp-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-4", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: Option.selectable_kubernetes_versions.first, enable_ip4: true, kubernetes_cluster_id: kc.id)
    Prog::Kubernetes::KubernetesNodeNexus.assemble(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "w1-node", location_id: Location::HETZNER_FSN1_ID, size: "standard-4", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: Option.selectable_kubernetes_versions.first, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
    kc
  }
  let(:probe_subnet) { Prog::Vnet::SubnetNexus.assemble(kubernetes_test_project.id, name: "kubernetes-test-firewall-probe-subnet", location_id: Location::HETZNER_FSN1_ID).subject }
  let(:probe_vm) { Prog::Vm::Nexus.assemble_with_sshable(kubernetes_test_project.id, sshable_unix_user: "ubi", name: "kubernetes-test-firewall-probe", private_subnet_id: probe_subnet.id, boot_image: "ubuntu-noble", enable_ip4: true).subject }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(kubernetes_service_project.id)
  end

  describe ".assemble" do
    let(:strand_stack) { [{}] }

    it "assembles a single-worker firewall test cluster" do
      expect(Config).to receive(:kubernetes_service_project_id).at_least(:once).and_return("4fd01c1a-f022-43e8-bd3d-6dbe214df6ed")
      st = described_class.assemble
      expect(st.prog).to eq("Test::KubernetesFirewall")
      expect(st.label).to eq("start")
      expect(st.stack.first["cluster_name"]).to eq("kubernetes-test-firewall")
      expect(st.stack.first["worker_node_count"]).to eq(1)
    end
  end

  describe "#wait_for_kubernetes_bootstrap" do
    it "hops to test_node_isolation if cluster is ready" do
      kubernetes_cluster.strand.update(label: "wait")
      expect { kubernetes_test.wait_for_kubernetes_bootstrap }.to hop("test_node_isolation")
    end

    it "naps if cluster is not ready" do
      expect { kubernetes_test.wait_for_kubernetes_bootstrap }.to nap(10)
    end
  end

  describe "#test_node_isolation" do
    let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id, "kubernetes_test_project_id" => kubernetes_test_project.id, "cluster_name" => "kubernetes-test-firewall"}] }

    it "provisions a probe vm in a separate subnet and hops to wait_probe_vm" do
      expect { kubernetes_test.test_node_isolation }.to hop("wait_probe_vm")
      stack = kubernetes_test.strand.stack.first
      probe = Vm[stack["probe_vm_id"]]
      expect(probe.name).to eq "kubernetes-test-firewall-probe"
      expect(probe.private_subnets.first.id).to eq stack["probe_subnet_id"]
      expect(PrivateSubnet[stack["probe_subnet_id"]].name).to eq "kubernetes-test-firewall-probe-subnet"
    end
  end

  describe "#wait_probe_vm" do
    let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id, "probe_vm_id" => probe_vm.id}] }

    it "naps until the probe vm is running" do
      probe_vm.strand.update(label: "start")
      expect { kubernetes_test.wait_probe_vm }.to nap(10)
    end

    it "installs netcat and hops to verify_node_isolation" do
      probe_vm.strand.update(label: "wait")
      expect(kubernetes_test.probe_vm.sshable).to receive(:_cmd).with("sudo apt-get update && sudo apt-get install -y netcat-openbsd")
      expect { kubernetes_test.wait_probe_vm }.to hop("verify_node_isolation")
    end
  end

  describe "#verify_node_isolation" do
    let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id, "probe_vm_id" => probe_vm.id}] }

    before do
      kubernetes_cluster.all_nodes.each_with_index do |n, i|
        n.vm.update(ephemeral_net6: "2a01:4f8:10a:128#{i}::/64")
        AssignedVmAddress.create(dst_vm_id: n.vm.id, ip: "1.2.3.#{i}/32")
      end
    end

    it "hops to teardown_probe when the probe cannot reach any node over IPv4 or IPv6" do
      kubernetes_cluster.all_nodes.each do |node|
        expect(kubernetes_test.probe_vm.sshable).to receive(:_cmd).with("nc -zvw 5 -4 #{node.vm.ip4_string} 10250").and_raise(Sshable::SshError.new("blocked", "", "", 1, nil))
        expect(kubernetes_test.probe_vm.sshable).to receive(:_cmd).with("nc -zvw 5 -6 #{node.vm.ip6_string} 10250").and_raise(Sshable::SshError.new("blocked", "", "", 1, nil))
      end
      expect { kubernetes_test.verify_node_isolation }.to hop("teardown_probe")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to be_nil
    end

    it "sets fail_message when the probe can reach a node over IPv4" do
      node = kubernetes_cluster.all_nodes.first
      expect(kubernetes_test.probe_vm.sshable).to receive(:_cmd).with("nc -zvw 5 -4 #{node.vm.ip4_string} 10250").and_return("succeeded")
      expect { kubernetes_test.verify_node_isolation }.to hop("teardown_probe")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq "node #{node.name} is reachable on port 10250 from a foreign subnet despite the locked-down customer firewall"
    end

    it "sets fail_message when the probe can reach a node only over IPv6" do
      node = kubernetes_cluster.all_nodes.first
      expect(kubernetes_test.probe_vm.sshable).to receive(:_cmd).with("nc -zvw 5 -4 #{node.vm.ip4_string} 10250").and_raise(Sshable::SshError.new("blocked", "", "", 1, nil))
      expect(kubernetes_test.probe_vm.sshable).to receive(:_cmd).with("nc -zvw 5 -6 #{node.vm.ip6_string} 10250").and_return("succeeded")
      expect { kubernetes_test.verify_node_isolation }.to hop("teardown_probe")
      expect(kubernetes_test.strand.stack.first["fail_message"]).to eq "node #{node.name} is reachable on port 10250 from a foreign subnet despite the locked-down customer firewall"
    end
  end

  describe "#teardown_probe" do
    let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id, "probe_vm_id" => probe_vm.id, "probe_subnet_id" => probe_subnet.id}] }

    it "destroys the probe vm, its firewall, and its subnet, then hops" do
      firewall = probe_subnet.firewalls.first
      expect { kubernetes_test.teardown_probe }.to hop("wait_probe_teardown").and change { Firewall.where(id: firewall.id).count }.from(1).to(0)
      expect(probe_vm.reload.destroy_set?).to be true
      expect(probe_subnet.reload.destroy_set?).to be true
    end
  end

  describe "#wait_probe_teardown" do
    context "when the probe vm still exists" do
      let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id, "probe_vm_id" => probe_vm.id, "probe_subnet_id" => probe_subnet.id}] }

      it "naps" do
        expect { kubernetes_test.wait_probe_teardown }.to nap(5)
      end
    end

    context "when only the probe subnet remains" do
      let(:strand_stack) { [{"kubernetes_cluster_id" => kubernetes_cluster.id, "probe_subnet_id" => probe_subnet.id}] }

      it "naps" do
        expect { kubernetes_test.wait_probe_teardown }.to nap(5)
      end
    end

    context "when the probe vm and subnet are gone" do
      it "hops to destroy_kubernetes" do
        expect { kubernetes_test.wait_probe_teardown }.to hop("destroy_kubernetes")
      end
    end
  end
end
