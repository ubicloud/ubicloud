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
      version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-4",
      target_node_storage_size_gib: 37
    )

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "somelb", health_check_endpoint: "/foo", project_id: Config.kubernetes_service_project_id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    kc.add_cp_vm(create_vm)
    kc.add_cp_vm(create_vm)

    kc.update(api_server_lb_id: lb.id)
    kc
  }

  let(:kubernetes_nodepool) {
    kn = KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kubernetes_cluster.id, target_node_size: "standard-8", target_node_storage_size_gib: 78)
    kn.add_vm(create_vm)
    kn.add_vm(create_vm)
    kn.reload
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
      Strand.create(parent_id: st.id, prog: "Kubernetes::ProvisionKubernetesNode", label: "start", stack: [{}], exitval: {"vm_id" => "12345"})
      expect { prog.wait_new_node }.to hop("drain_old_node")
      expect(prog.strand.stack.first["new_vm_id"]).to eq "12345"
    end
  end

  describe "#drain_old_node" do
    let(:sshable) { instance_double(Sshable) }
    let(:old_vm) { create_vm }

    before do
      allow(prog).to receive(:frame).and_return({"old_vm_id" => old_vm.id})
      expect(prog.old_vm.id).to eq(old_vm.id)
      cp_vm = create_vm
      expect(kubernetes_cluster).to receive(:cp_vms).and_return([old_vm, cp_vm])
      allow(cp_vm).to receive(:sshable).and_return(sshable)

      expect(prog).to receive(:register_deadline).with("remove_old_node_from_cluster", 60 * 60)
    end

    it "starts the drain process when run for the first time and naps" do
      expect(sshable).to receive(:d_check).with("drain_node").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("drain_node", "sudo", "kubectl", "--kubeconfig=/etc/kubernetes/admin.conf", "drain", old_vm.name, "--ignore-daemonsets", "--delete-emptydir-data")
      expect { prog.drain_old_node }.to nap(10)
    end

    it "naps when the node is getting drained" do
      expect(sshable).to receive(:d_check).with("drain_node").and_return("InProgress")
      expect { prog.drain_old_node }.to nap(10)
    end

    it "restarts when it fails" do
      expect(sshable).to receive(:d_check).with("drain_node").and_return("Failed")
      expect(sshable).to receive(:d_restart).with("drain_node")
      expect { prog.drain_old_node }.to nap(10)
    end

    it "naps when daemonizer something unexpected and waits for the page" do
      expect(sshable).to receive(:d_check).with("drain_node").and_return("UnexpectedState")
      expect { prog.drain_old_node }.to nap(60 * 60)
    end

    it "drains the old node and hops to drop the old node" do
      expect(sshable).to receive(:d_check).with("drain_node").and_return("Succeeded")
      expect { prog.drain_old_node }.to hop("remove_old_node_from_cluster")
    end
  end

  describe "#remove_old_node_from_cluster" do
    before do
      old_vm = create_vm
      new_vm = create_vm
      allow(prog).to receive(:frame).and_return({"old_vm_id" => old_vm.id, "new_vm_id" => new_vm.id})
      expect(prog.old_vm.id).to eq(old_vm.id)
      expect(prog.new_vm.id).to eq(new_vm.id)

      expect(kubernetes_nodepool.vms.count).to eq(2)
      expect(kubernetes_cluster.reload.all_vms.map(&:id)).to eq((kubernetes_cluster.cp_vms + kubernetes_nodepool.vms).map(&:id))

      mock_sshable = instance_double(Sshable)
      expect(prog.old_vm).to receive(:sshable).and_return(mock_sshable)
      expect(mock_sshable).to receive(:cmd).with("sudo kubeadm reset --force")
    end

    it "removes the old node from the CP while upgrading the control plane" do
      expect(prog.kubernetes_nodepool).to be_nil
      api_server_lb = instance_double(LoadBalancer)
      expect(kubernetes_cluster).to receive(:api_server_lb).and_return(api_server_lb)
      expect(kubernetes_cluster).to receive(:remove_cp_vm).with(prog.old_vm)
      expect(api_server_lb).to receive(:detach_vm).with(prog.old_vm)
      expect { prog.remove_old_node_from_cluster }.to hop("delete_node_object")
    end

    it "removes the old node from the nodepool while upgrading the node pool" do
      allow(prog).to receive(:frame).and_return({"old_vm_id" => prog.old_vm.id, "new_vm_id" => prog.new_vm.id, "nodepool_id" => kubernetes_nodepool.id})
      expect(prog.kubernetes_nodepool).not_to be_nil
      expect(prog.kubernetes_nodepool).to receive(:remove_vm).with(prog.old_vm)
      expect { prog.remove_old_node_from_cluster }.to hop("delete_node_object")
    end
  end

  describe "#delete_node_object" do
    before do
      old_vm = create_vm
      allow(prog).to receive(:frame).and_return({"old_vm_id" => old_vm.id})
      expect(prog.old_vm.id).to eq(old_vm.id)
    end

    it "deletes the node object from kubernetes" do
      client = instance_double(Kubernetes::Client)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
      expect(client).to receive(:delete_node).with(prog.old_vm.name).and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("success", 0))
      expect { prog.delete_node_object }.to hop("destroy_node")
    end

    it "raises if the error of delete node command is not successful" do
      client = instance_double(Kubernetes::Client)
      expect(kubernetes_cluster).to receive(:client).and_return(client)
      expect(client).to receive(:delete_node).with(prog.old_vm.name).and_return(Net::SSH::Connection::Session::StringWithExitstatus.new("failed", 1))
      expect { prog.delete_node_object }.to raise_error(RuntimeError)
    end
  end

  describe "#destroy_node" do
    before do
      old_vm = create_vm
      allow(prog).to receive(:frame).and_return({"old_vm_id" => old_vm.id})
      expect(prog.old_vm.id).to eq(old_vm.id)
    end

    it "destroys the old node" do
      expect(prog.old_vm).to receive(:incr_destroy)
      expect { prog.destroy_node }.to exit({"msg" => "upgraded node"})
    end
  end
end
