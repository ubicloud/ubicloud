# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::UpgradeKubernetesNode do
  subject(:prog) { described_class.new(st) }

  let(:st) { Strand.create(prog: "Kubernetes::UpgradeKubernetesNode", label: "start", stack: [{"subject_id" => kubernetes_cluster.id}]) }

  let(:project) {
    Project.create(name: "default")
  }

  let(:kubernetes_cluster) {
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "k8scluster",
      version: Option.selectable_kubernetes_versions.first,
      cp_node_count: 3,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-4",
      target_node_storage_size_gib: 37,
    ).subject

    lb = LoadBalancer.create(private_subnet_id: kc.private_subnet_id, name: "somelb", health_check_endpoint: "/foo", project_id: Config.kubernetes_service_project_id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    kc.update(api_server_lb_id: lb.id)
  }

  let(:kubernetes_nodepool) {
    Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "nodepool", node_count: 2, kubernetes_cluster_id: kubernetes_cluster.id, target_node_size: "standard-8", target_node_storage_size_gib: 78).subject
  }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

  describe "#before_run" do
    before do
      kubernetes_cluster.strand.update(label: "wait")
    end

    it "exits when kubernetes cluster is deleted and has no children itself" do
      st.update(label: "somestep")
      prog.before_run # Nothing happens

      prog.kubernetes_cluster.strand.update(label: "destroy")
      expect { prog.before_run }.to exit({"msg" => "upgrade cancelled"})
    end

    it "donates when kubernetes cluster is deleted and but has a child" do
      st.update(label: "somestep")
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      prog.kubernetes_cluster.strand.update(label: "destroy")
      expect { prog.before_run }.to nap(120)
    end
  end

  describe "#start" do
    it "registers a deadline and provisions a replacement control plane node" do
      expect { prog.start }.to hop("wait_new_node")

      expect(Time.new(prog.strand.stack.first["deadline_at"])).to be_within(60).of(Time.now + 30 * 60)
      expect(st.children.map { [it.prog, it.stack.first] }).to eq [["Kubernetes::ProvisionKubernetesNode", {"subject_id" => kubernetes_cluster.id}]]
    end

    it "passes the nodepool on to the replacement worker node" do
      st.update(stack: [{"subject_id" => kubernetes_cluster.id, "nodepool_id" => kubernetes_nodepool.id}])

      expect { prog.start }.to hop("wait_new_node")

      expect(st.children.map { it.stack.first }).to eq [{"subject_id" => kubernetes_cluster.id, "nodepool_id" => kubernetes_nodepool.id}]
    end
  end

  describe "#wait_new_node" do
    it "donates if there are sub-programs running" do
      st.update(label: "wait_new_node")
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], lease: Time.now + 10)
      expect { prog.wait_new_node }.to nap(120)
    end

    it "hops to wait_node_ready if there are no sub-programs running" do
      st.update(label: "wait_new_node")
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], exitval: {"node_id" => "12345"})
      expect { prog.wait_new_node }.to hop("wait_node_ready")
      expect(prog.strand.stack.first["new_node_id"]).to eq "12345"
    end
  end

  describe "#wait_node_ready" do
    let(:session) { Net::SSH::Connection::Session.allocate }
    let(:new_node) { assemble_node("new-node") }

    before do
      st.update(stack: [{"subject_id" => kubernetes_cluster.id, "new_node_id" => new_node.id, "old_node_id" => "old"}])
      expect(prog.kubernetes_cluster.sshable).to receive(:connect).and_return(session)
    end

    it "naps if the new node is not yet Ready" do
      body = JSON.generate("items" => [{"metadata" => {"name" => new_node.name}, "status" => {"conditions" => [{"type" => "Ready", "status" => "False"}]}}])
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -ojson").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new(body, 0))
      expect { prog.wait_node_ready }.to nap(10)
    end

    it "hops to upgrade_kubeadm once every functional node is Ready" do
      body = JSON.generate("items" => [{"metadata" => {"name" => new_node.name}, "status" => {"conditions" => [{"type" => "Ready", "status" => "True"}]}}])
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get nodes -ojson").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new(body, 0))
      expect { prog.wait_node_ready }.to hop("upgrade_kubeadm")
    end
  end

  describe "#upgrade_kubeadm" do
    let(:new_node) { assemble_node("new-node") }
    let(:session) { Net::SSH::Connection::Session.allocate }
    let(:get_kubeadm_config) { "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'" }

    before do
      st.update(stack: [{"subject_id" => kubernetes_cluster.id, "new_node_id" => new_node.id, "old_node_id" => "old"}])
    end

    def expect_recorded_version(version)
      expect(prog.kubernetes_cluster.sshable).to receive(:connect).and_return(session)
      expect(session).to receive(:_exec!).with(get_kubeadm_config).and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("kubernetesVersion: #{version}.0\n", 0))
    end

    it "skips kubeadm upgrade for worker (nodepool) replacements" do
      st.update(stack: [{"subject_id" => kubernetes_cluster.id, "new_node_id" => new_node.id, "old_node_id" => "old", "nodepool_id" => kubernetes_nodepool.id}])
      expect(prog.new_node.vm.sshable).not_to receive(:d_check)
      expect { prog.upgrade_kubeadm }.to hop("drain_old_node")
    end

    it "skips kubeadm upgrade when the cluster is already recorded at the target version" do
      expect_recorded_version(kubernetes_cluster.version)
      expect(prog.new_node.vm.sshable).not_to receive(:d_check)
      expect { prog.upgrade_kubeadm }.to hop("drain_old_node")
    end

    context "when the ConfigMap is behind the cluster version" do
      before do
        expect_recorded_version("v1.99")
      end

      it "starts kubeadm upgrade apply on the new node when not started yet" do
        expect(prog.new_node.vm.sshable).to receive(:d_check).with("kubeadm_upgrade_apply").and_return("NotStarted")
        expect(prog.new_node.vm.sshable).to receive(:d_run).with(
          "kubeadm_upgrade_apply", "bash", "-c",
          "sudo kubeadm upgrade apply --yes $(kubeadm version -o short)",
        )
        expect { prog.upgrade_kubeadm }.to nap(30)
      end

      it "naps while the upgrade is in progress" do
        expect(prog.new_node.vm.sshable).to receive(:d_check).with("kubeadm_upgrade_apply").and_return("InProgress")
        expect { prog.upgrade_kubeadm }.to nap(30)
      end

      it "hops to drain_old_node when the upgrade succeeded" do
        expect(prog.new_node.vm.sshable).to receive(:d_check).with("kubeadm_upgrade_apply").and_return("Succeeded")
        expect { prog.upgrade_kubeadm }.to hop("drain_old_node")
      end

      it "logs and naps long when the upgrade failed" do
        expect(prog.new_node.vm.sshable).to receive(:d_check).with("kubeadm_upgrade_apply").and_return("Failed")
        expect { prog.upgrade_kubeadm }.to nap(65536)
      end

      it "naps long for an unknown daemonizer state" do
        expect(prog.new_node.vm.sshable).to receive(:d_check).with("kubeadm_upgrade_apply").and_return("Whatever")
        expect { prog.upgrade_kubeadm }.to nap(65536)
      end
    end
  end

  describe "#drain_old_node" do
    it "retires the old node and hops" do
      old_node = assemble_node("old-node")
      st.update(stack: [{"subject_id" => kubernetes_cluster.id, "old_node_id" => old_node.id}])

      expect { prog.drain_old_node }.to hop("wait_for_drain")
      expect(old_node.retire_set?).to be true
    end
  end

  describe "#wait_for_drain" do
    let(:old_node) { assemble_node("old-node") }

    before do
      st.update(stack: [{"subject_id" => kubernetes_cluster.id, "old_node_id" => old_node.id}])
    end

    it "naps if node is not drained yet" do
      expect { prog.wait_for_drain }.to nap(5)
    end

    it "hops to destroy when node is retired" do
      old_node.destroy
      expect { prog.wait_for_drain }.to hop("destroy")
    end
  end

  describe "#destroy" do
    it "pops after the old node is gone" do
      expect { prog.destroy }.to exit({"msg" => "upgraded node"})
    end
  end

  def assemble_node(name)
    Prog::Kubernetes::KubernetesNodeNexus.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name:, location_id: kubernetes_cluster.location_id, size: kubernetes_cluster.target_node_size, storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-#{kubernetes_cluster.version.tr(".", "_")}", enable_ip4: true, kubernetes_cluster_id: kubernetes_cluster.id).subject
  end
end
