# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesNodepoolNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:project) { Project.create_with_id(name: "default") }
  let(:subnet) { PrivateSubnet.create_with_id(net6: "0::0", net4: "127.0.0.1", name: "x", location: "x", project_id: project.id) }

  let(:kc) {
    kc = KubernetesCluster.create_with_id(
      name: "k8scluster",
      kubernetes_version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location: "hetzner-fsn1",
      project_id: project.id
    )

    lb = LoadBalancer.create_with_id(private_subnet_id: subnet.id, name: "somelb", src_port: 123, dst_port: 456, health_check_endpoint: "/foo", project_id: project.id)
    kc.add_cp_vm(create_vm)
    kc.add_cp_vm(create_vm)
    kc.update(api_server_lb_id: lb.id)
    kc
  }

  let(:kn) {
    kn = KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id)
    kn.add_vm(create_vm)
    kn.add_vm(create_vm)
    kn
  }

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
      st = described_class.assemble(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kc.id)

      expect(st.subject.name).to eq "k8stest-np"
      expect(st.subject.ubid).to start_with("kn")
      expect(st.subject.kubernetes_cluster_id).to eq kc.id
      expect(st.subject.node_count).to eq 2
      expect(st.label).to eq "start"
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
      expect(kn.kubernetes_cluster).to receive(:strand).and_return(Strand.new(label: "not-wait"))
      expect { nx.start }.to nap(30)
    end

    it "registers a deadline and hops if the cluster is ready" do
      expect(kn.kubernetes_cluster).to receive(:strand).and_return(Strand.new(label: "wait"))
      expect(nx).to receive(:register_deadline)
      expect { nx.start }.to hop("bootstrap_worker_vms")
    end
  end

  describe "#bootstrap_worker_vms" do
    it "hops wait if the target number of vms is reached" do
      expect { nx.bootstrap_worker_vms }.to hop("wait")
    end

    it "pushes ProvisionKubernetesNode prog to create VMs" do
      expect(kn).to receive(:vms).and_return ["just one vm"]
      expect(nx).to receive(:push).with(Prog::Kubernetes::ProvisionKubernetesNode, {"nodepool_id" => kn.id, "subject_id" => kn.kubernetes_cluster.id})
      nx.bootstrap_worker_vms
    end
  end

  describe "#wait" do
    it "naps by default" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to upgrade when semaphore is set" do
      expect(nx).to receive(:when_upgrade_set?).and_yield
      expect { nx.wait }.to hop("upgrade")
    end
  end

  describe "#upgrade" do
    it "picks a node to upgrade and pushes UpgradeKubernetesNode prog with it" do
      ssh0 = instance_double(Sshable)
      expect(ssh0).to receive(:cmd).with("sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf version").and_return("Client Version: v1.32.1")
      expect(kn.vms[0]).to receive(:sshable).and_return(ssh0)

      ssh1 = instance_double(Sshable)
      expect(ssh1).to receive(:cmd).with("sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf version").and_return("Client Version: v1.31.3")
      expect(kn.vms[1]).to receive(:sshable).and_return(ssh1)

      expect(nx).to receive(:push).with(Prog::Kubernetes::UpgradeKubernetesNode, {"nodepool_id" => kn.id, "old_vm_id" => kn.vms[1].id, "subject_id" => kc.id})

      nx.upgrade
    end

    it "returns to wait if all nodes are in desired version" do
      ssh0 = instance_double(Sshable)
      expect(ssh0).to receive(:cmd).with("sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf version").and_return("Client Version: v1.32.1")
      expect(kn.vms[0]).to receive(:sshable).and_return(ssh0)

      ssh1 = instance_double(Sshable)
      expect(ssh1).to receive(:cmd).with("sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf version").and_return("Client Version: v1.32.3")
      expect(kn.vms[1]).to receive(:sshable).and_return(ssh1)

      expect { nx.upgrade }.to hop("wait")
    end
  end

  describe "#destroy" do
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
