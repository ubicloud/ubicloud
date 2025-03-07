# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesNodepoolNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:project) { Project.create(name: "default") }
  let(:subnet) { PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location: "x", project_id: project.id) }

  let(:kc) {
    kc = KubernetesCluster.create(
      name: "k8scluster",
      version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location: "hetzner-fsn1",
      project_id: project.id,
      target_node_size: "standard-2"
    )

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", src_port: 123, dst_port: 456, health_check_endpoint: "/foo", project_id: project.id)
    kc.add_cp_vm(create_vm)
    kc.add_cp_vm(create_vm)
    kc.update(api_server_lb_id: lb.id)
    kc
  }

  let(:kn) { KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2") }

  before do
    allow(nx).to receive(:kubernetes_nodepool).and_return(kn)
  end

  describe ".assemble" do
    it "validates input" do
      expect {
        described_class.assemble(name: "name", node_count: 2, kubernetes_cluster_id: SecureRandom.uuid)
      }.to raise_error RuntimeError, "No existing cluster"
    end

    it "creates a kubernetes nodepool" do
      st = described_class.assemble(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-4", target_node_storage_size_gib: 37)
      kn = st.subject

      expect(kn.name).to eq "k8stest-np"
      expect(kn.ubid).to start_with("kn")
      expect(kn.kubernetes_cluster_id).to eq kc.id
      expect(kn.node_count).to eq 2
      expect(st.label).to eq "start"
      expect(kn.target_node_size).to eq "standard-4"
      expect(kn.target_node_storage_size_gib).to eq 37
    end

    it "can have null as storage size" do
      st = described_class.assemble(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-4", target_node_storage_size_gib: nil)

      expect(st.subject.target_node_storage_size_gib).to be_nil
    end
  end

  describe "#before_run" do
    it "hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if the kubernetes cluster is not ready" do
      expect(kn.cluster).to receive(:strand).and_return(Strand.new(label: "not-wait"))
      expect { nx.start }.to nap(30)
    end

    it "registers a deadline and hops if the cluster is ready" do
      expect(kn.cluster).to receive(:strand).and_return(Strand.new(label: "wait"))
      expect(nx).to receive(:register_deadline)
      expect { nx.start }.to hop("bootstrap_worker_vms")
    end
  end

  describe "#bootstrap_worker_vms" do
    it "hops wait if the target number of vms is reached" do
      expect(kn).to receive(:vms).and_return [1, 2]
      expect { nx.bootstrap_worker_vms }.to hop("wait")
    end

    it "buds ProvisionKubernetesNode prog to create VMs" do
      expect(nx).to receive(:bud).with(Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kn.id, "subject_id" => kn.cluster.id})
      expect { nx.bootstrap_worker_vms }.to hop("wait_worker_node")
    end
  end

  describe "#wait_worker_node" do
    before { expect(nx).to receive(:reap) }

    it "hops back to bootstrap_worker_vms if there are no sub-programs running" do
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_worker_node }.to hop("bootstrap_worker_vms")
    end

    it "donates if there are sub-programs running" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_worker_node }.to nap(1)
    end
  end

  describe "#wait" do
    it "just naps for long time for now" do
      expect { nx.wait }.to nap(65536)
    end
  end

  describe "#destroy" do
    before { expect(nx).to receive(:reap) }

    it "donates if there are sub-programs running (Provision...)" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.destroy }.to nap(1)
    end

    it "destroys the nodepool and its vms" do
      vms = [create_vm, create_vm]
      expect(kn).to receive(:vms).and_return(vms)

      expect(vms).to all(receive(:incr_destroy))
      expect(kn).to receive(:remove_all_vms)
      expect(kn).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "kubernetes nodepool is deleted"})
    end
  end
end
