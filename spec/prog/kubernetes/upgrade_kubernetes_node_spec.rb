# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::UpgradeKubernetesNode do
  subject(:prog) { described_class.new(st) }

  let(:st) { Strand.new }

  let(:project) {
    Project.create(name: "default")
  }
  let(:subnet) {
    Prog::Vnet::SubnetNexus.assemble(Config.kubernetes_service_project_id, name: "test", ipv4_range: "172.19.0.0/16", ipv6_range: "fd40:1a0a:8d48:182a::/64").subject
  }

  let(:kubernetes_cluster) {
    kc = KubernetesCluster.create(
      name: "k8scluster",
      version: Option.kubernetes_versions.first,
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-4",
      target_node_storage_size_gib: 37
    )

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", health_check_endpoint: "/foo", project_id: Config.kubernetes_service_project_id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    kc.update(api_server_lb_id: lb.id)
  }

  let(:kubernetes_nodepool) {
    KubernetesNodepool.create(name: "nodepool", node_count: 2, kubernetes_cluster_id: kubernetes_cluster.id, target_node_size: "standard-8", target_node_storage_size_gib: 78)
  }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
    allow(prog).to receive(:kubernetes_cluster).and_return(kubernetes_cluster)
  end

  describe "#before_run" do
    before do
      Strand.create(id: kubernetes_cluster.id, label: "wait", prog: "KubernetesClusterNexus")
    end

    it "exits when kubernetes cluster is deleted and has no children itself" do
      st.update(prog: "Kubernetes::UpgradeKubernetesNode", label: "somestep", stack: [{}])
      prog.before_run # Nothing happens

      kubernetes_cluster.strand.label = "destroy"
      expect { prog.before_run }.to exit({"msg" => "upgrade cancelled"})
    end

    it "donates when kubernetes cluster is deleted and but has a child" do
      st.update(prog: "Kubernetes::UpgradeKubernetesNode", label: "somestep", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      kubernetes_cluster.strand.label = "destroy"
      expect { prog.before_run }.to nap(120)
    end
  end

  describe "#start" do
    it "provisions a new kubernetes node" do
      expect(prog).to receive(:frame).and_return({})
      expect(prog).to receive(:bud).with(Prog::Kubernetes::ProvisionKubernetesNode, {})
      expect { prog.start }.to hop("wait_new_node")

      expect(prog).to receive(:frame).and_return({"nodepool_id" => kubernetes_nodepool.id})
      expect(prog).to receive(:bud).with(Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kubernetes_nodepool.id})
      expect { prog.start }.to hop("wait_new_node")
    end
  end

  describe "#wait_new_node" do
    it "donates if there are sub-programs running" do
      st.update(prog: "Kubernetes::UpgradeKubernetesNode", label: "wait_new_node", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { prog.wait_new_node }.to nap(120)
    end

    it "hops to assign_role if there are no sub-programs running" do
      st.update(prog: "Kubernetes::UpgradeKubernetesNode", label: "wait_new_node", stack: [{}])
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], exitval: {"node_id" => "12345"})
      expect { prog.wait_new_node }.to hop("drain_old_node")
      expect(prog.strand.stack.first["new_node_id"]).to eq "12345"
    end
  end

  describe "#drain_old_node" do
    let(:sshable) { instance_double(Sshable) }
    let(:old_node) { KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kubernetes_cluster.id) }

    before do
      expect(prog).to receive(:frame).and_return({"old_node_id" => old_node.id})
      expect(prog.old_node.id).to eq(old_node.id)
    end

    it "starts the drain process when run for the first time and naps" do
      expect(prog.old_node).to receive(:incr_retire)
      expect { prog.drain_old_node }.to hop("wait_for_drain")
    end
  end

  describe "#wait_for_drain" do
    let(:old_node) { KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kubernetes_cluster.id) }

    before do
      expect(prog).to receive(:frame).and_return({"old_node_id" => old_node.id})
      expect(prog.old_node.id).to eq(old_node.id)
    end

    it "naps if node is not drained yet" do
      expect { prog.wait_for_drain }.to nap(5)
    end

    it "hops to destroy when node is retired" do
      expect(prog).to receive(:old_node).and_return(nil)
      expect { prog.wait_for_drain }.to hop("destroy")
    end
  end

  describe "#destroy_node" do
    it "destroys the old node" do
      expect { prog.destroy }.to exit({"msg" => "upgraded node"})
    end
  end
end
