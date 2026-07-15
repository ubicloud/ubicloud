# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesNodepoolNexus do
  subject(:nx) { described_class.new(kn.strand) }

  let(:project) { Project.create(name: "default") }
  let(:kc) {
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "k8scluster",
      version: Option.selectable_kubernetes_versions.first,
      cp_node_count: 3,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-2",
    ).subject

    lb = LoadBalancer.create(private_subnet_id: kc.private_subnet_id, name: "somelb", health_check_endpoint: "/foo", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    [create_vm, create_vm].each do |vm|
      KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id)
    end
    kc.update(api_server_lb_id: lb.id)
  }
  let(:kn) {
    kn = described_class.assemble(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
    [create_vm, create_vm].each do |vm|
      KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)
    end
    kn
  }

  before do
    prj = Project.create(name: "UbicloudKubernetesService")
    allow(Config).to receive(:kubernetes_service_project_id).and_return(prj.id)
    allow(nx).to receive(:kubernetes_nodepool).and_return(kn)
  end

  describe ".assemble" do
    it "validates input" do
      expect {
        described_class.assemble(name: "name", node_count: 2, kubernetes_cluster_id: SecureRandom.uuid)
      }.to raise_error RuntimeError, "No existing cluster"

      expect {
        described_class.assemble(name: "name", node_count: 0, kubernetes_cluster_id: kc.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: worker_node_count"

      expect {
        described_class.assemble(name: "name", node_count: "2", kubernetes_cluster_id: kc.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: worker_node_count"

      expect {
        described_class.assemble(name: "INVALID_NAME", node_count: 2, kubernetes_cluster_id: kc.id)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"
    end

    it "creates a kubernetes nodepool" do
      st = described_class.assemble(name: "k8stest-np2", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-4", target_node_storage_size_gib: 37)
      kn = st.subject

      expect(kn.name).to eq "k8stest-np2"
      expect(kn.ubid).to start_with("kn")
      expect(kn.kubernetes_cluster_id).to eq kc.id
      expect(kn.node_count).to eq 2
      expect(st.label).to eq "start"
      expect(kn.target_node_size).to eq "standard-4"
      expect(kn.target_node_storage_size_gib).to eq 37
    end

    it "can have null as storage size" do
      st = described_class.assemble(name: "k8stest-np2", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-4", target_node_storage_size_gib: nil)

      expect(st.subject.target_node_storage_size_gib).to be_nil
    end

    it "requests bootstrapping only when the cluster is already in wait" do
      st = described_class.assemble(name: "k8stest-np2", node_count: 2, kubernetes_cluster_id: kc.id)
      expect(st.subject.start_bootstrapping_set?).to be false

      kc.strand.update(label: "wait")
      st = described_class.assemble(name: "k8stest-np3", node_count: 2, kubernetes_cluster_id: kc.id)
      expect(st.subject.start_bootstrapping_set?).to be true
    end
  end

  describe "#start" do
    it "naps if the kubernetes cluster is not ready" do
      expect { nx.start }.to nap(10)
    end

    it "registers a deadline, consumes the semaphore and hops if the cluster is ready" do
      kn.incr_start_bootstrapping
      prog = described_class.new(kn.strand)
      expect { prog.start }.to hop("bootstrap_worker_nodes")
        .and change { Semaphore.where(strand_id: kn.id, name: "start_bootstrapping").count }.from(1).to(0)
      expect(Time.parse(prog.strand.stack.first["deadline_at"])).to be_within(60).of(Time.now + 120 * 60)
    end

    it "hops when the cluster is in wait even without the semaphore" do
      kn
      kc.strand.update(label: "wait")
      expect { described_class.new(kn.strand).start }.to hop("bootstrap_worker_nodes")
    end
  end

  describe "#bootstrap_worker_nodes" do
    it "buds enough number of times ProvisionKubernetesNode progs when we need to provision more nodes" do
      kn.update(node_count: 4)
      (kn.node_count - kn.functional_nodes.count).times do
        expect(nx).to receive(:bud).with(Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kn.id, "subject_id" => kn.cluster.id})
      end
      expect { nx.bootstrap_worker_nodes }.to hop("wait_worker_node")
    end

    it "retires enough number of nodes when we need to decommission some" do
      kn.update(node_count: 1)
      expect(kn.functional_nodes.first).to receive(:incr_retire)
      expect { nx.bootstrap_worker_nodes }.to hop("wait_worker_node")
    end

    it "does nothing when we have the right number of nodes" do
      expect { nx.bootstrap_worker_nodes }.to hop("wait_worker_node")
    end
  end

  describe "#wait_worker_node" do
    it "hops to wait if there are no sub-programs running" do
      kn.strand.update(label: "wait_worker_node")
      expect { nx.wait_worker_node }.to hop("wait")
    end

    it "donates if there are sub-programs running" do
      kn.strand.update(label: "wait_worker_node")
      Strand.create(parent_id: kn.strand.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", lease: Time.now + 10)
      expect { nx.wait_worker_node }.to nap(120)
    end
  end

  describe "#wait" do
    it "naps for 6 hours" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to upgrade when semaphore is set" do
      expect(nx).to receive(:when_upgrade_set?).and_yield
      expect { nx.wait }.to hop("upgrade")
    end

    it "hops to bootstrap_worker_nodes when its semaphore is set" do
      expect(nx).to receive(:when_scale_worker_count_set?).and_yield
      expect(nx).to receive(:decr_scale_worker_count)
      expect { nx.wait }.to hop("bootstrap_worker_nodes")
    end
  end

  describe "#upgrade" do
    let(:first_node) { kn.nodes[0] }
    let(:second_node) { kn.nodes[1] }
    let(:client) { instance_double(Kubernetes::Client) }
    let(:cluster_version) { Option.kubernetes_versions[0] }
    let(:older_version) { Option.kubernetes_versions[1] }
    let(:much_older_version) { Option.kubernetes_versions[2] }
    let(:newer_version) {
      major, minor = cluster_version.match(/^v(\d+)\.(\d+)$/).captures.map(&:to_i)
      "v#{major}.#{minor + 1}"
    }

    context "when cluster is not upgrading" do
      before do
        kc.strand.update(label: "wait")
        sshable0, sshable1 = Sshable.new, instance_double(Sshable)
        allow(first_node).to receive(:sshable).and_return(sshable0)
        allow(second_node).to receive(:sshable).and_return(sshable1)
        allow(sshable0).to receive(:connect)
        allow(sshable1).to receive(:connect)

        expect(kn.cluster).to receive(:client).and_return(client).at_least(:once)
      end

      it "selects a node with minor version one less than the cluster's version" do
        expect(client).to receive(:version).and_return(cluster_version, older_version)
        expect { nx.upgrade }.to hop("wait_upgrade")
        st = Strand[prog: "Kubernetes::UpgradeKubernetesNode"]
        expect(st).not_to be_nil
        expect(st.stack.first).to eq({"nodepool_id" => kn.id, "old_node_id" => second_node.id, "subject_id" => kn.cluster.id})
      end

      it "hops to wait when all nodes are at the cluster's version" do
        expect(client).to receive(:version).and_return(cluster_version, cluster_version)
        expect { nx.upgrade }.to hop("wait")
      end

      it "selects a node multiple minor versions behind the nodepool version" do
        expect(client).to receive(:version).and_return(much_older_version)
        expect { nx.upgrade }.to hop("wait_upgrade")
        st = Strand[prog: "Kubernetes::UpgradeKubernetesNode"]
        expect(st.stack.first).to eq({"nodepool_id" => kn.id, "old_node_id" => first_node.id, "subject_id" => kn.cluster.id})
      end

      it "selects a node one minor version behind the nodepool version" do
        kn.update(version: older_version)
        expect(client).to receive(:version).and_return(much_older_version)
        expect { nx.upgrade }.to hop("wait_upgrade")
        st = Strand[prog: "Kubernetes::UpgradeKubernetesNode"]
        expect(st.stack.first).to eq({"nodepool_id" => kn.id, "old_node_id" => first_node.id, "subject_id" => kn.cluster.id})
      end

      it "skips nodes with invalid version formats and creates a page" do
        expect(client).to receive(:version).and_return("invalid", "invalid")
        expect { nx.upgrade }.to hop("wait")

        page = Page.from_tag_parts("K8sInvalidVersion", kc.ubid, first_node.name)
        expect(page).not_to be_nil
        expect(page.summary).to eq "Invalid version format for #{first_node.name} of cluster #{kc.ubid}"
        expect(page.details["node_version"]).to eq "invalid"
        expect(page.details["nodepool_version"]).to eq kn.version
      end

      it "selects the first node that is one minor version behind" do
        expect(client).to receive(:version).and_return(older_version)
        expect { nx.upgrade }.to hop("wait_upgrade")
        st = Strand[prog: "Kubernetes::UpgradeKubernetesNode"]
        expect(st).not_to be_nil
        expect(st.stack.first).to eq({"nodepool_id" => kn.id, "old_node_id" => first_node.id, "subject_id" => kn.cluster.id})
      end

      it "does not select a node with a higher minor version than the cluster" do
        expect(client).to receive(:version).and_return(newer_version, newer_version)
        expect { nx.upgrade }.to hop("wait")
      end
    end
  end

  describe "#wait_upgrade" do
    it "hops back to upgrade if there are no sub-programs running" do
      kn.strand.update(label: "wait_upgrade")
      expect { nx.wait_upgrade }.to hop("upgrade")
    end

    it "donates if there are sub-programs running" do
      kn.strand.update(label: "wait_upgrade")
      Strand.create(parent_id: kn.strand.id, prog: "Kubernetes::UpgradeKubernetesNode", label: "start", lease: Time.now + 10)
      expect { nx.wait_upgrade }.to nap(120)
    end
  end

  describe "#destroy" do
    it "donates if there are sub-programs running (Provision...)" do
      kn.strand.update(label: "wait_upgrade")
      Strand.create(parent_id: kn.strand.id, prog: "Kubernetes::UpgradeKubernetesNode", label: "start", lease: Time.now + 10)
      expect { nx.destroy }.to nap(120)
    end

    it "completes destroy when nodes are gone" do
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kn.cluster.id, kubernetes_nodepool_id: kn.id)
      kn.strand.update(label: "destroy")
      expect(kn.nodes).to all(receive(:incr_destroy))

      expect { nx.destroy }.to nap(5)
    end

    it "destroys the nodepool and its nodes" do
      kn.nodes_dataset.destroy

      expect(kn.nodes).to all(receive(:incr_destroy))
      expect(kn).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "kubernetes nodepool is deleted"})
    end
  end
end
