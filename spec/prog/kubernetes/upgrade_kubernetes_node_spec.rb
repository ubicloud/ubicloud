# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::UpgradeKubernetesNode do
  subject(:prog) { described_class.new(Strand.new) }

  let(:kubernetes_cluster) {
    project = Project.create_with_id(name: "default")
    subnet = PrivateSubnet.create_with_id(net6: "0::0/16", net4: "127.0.0.0/8", name: "x", location: "x", project_id: project.id)
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

  let(:kubernetes_nodepool) {
    kn = KubernetesNodepool.create(name: "k8stest-np", node_count: 2, kubernetes_cluster_id: kubernetes_cluster.id)
    kn.add_vm(create_vm)
    kn.add_vm(create_vm)
    kn.reload
  }

  before do
    allow(prog).to receive(:kubernetes_cluster).and_return(kubernetes_cluster)
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
      expect(prog).to receive(:reap).and_return([])
      expect(prog).to receive(:donate).and_call_original

      expect { prog.wait_new_node }.to nap(1)
    end

    it "hops to assign_role if there are no sub-programs running" do
      expect(prog).to receive(:reap).and_return([instance_double(Strand, exitval: {"vm_id" => "12345"})])

      expect { prog.wait_new_node }.to hop("drain_old_node")

      expect(prog.strand.stack.first["new_vm_id"]).to eq "12345"
    end
  end

  describe "#drain_old_node" do
    it "drains the old node and hops to drop the old node" do
      vm = create_vm
      allow(prog).to receive(:frame).and_return({"old_vm_id" => vm.id})
      expect(prog.old_vm.id).to eq(vm.id)

      expect(kubernetes_cluster).to receive(:kubectl).with("drain #{vm.inhost_name} --ignore-daemonsets")
      expect { prog.drain_old_node }.to hop("drop_old_node")
    end
  end

  describe "#drop_old_node" do
    before do
      old_vm = create_vm
      new_vm = create_vm
      allow(prog).to receive(:frame).and_return({"old_vm_id" => old_vm.id, "new_vm_id" => new_vm.id})
      expect(prog.old_vm.id).to eq(old_vm.id)
      expect(prog.new_vm.id).to eq(new_vm.id)

      allow(prog.old_vm).to receive(:ephemeral_net4).and_return("9.9.9.9")
      allow(prog.new_vm).to receive(:ephemeral_net4).and_return("7.7.7.7")

      expect(kubernetes_nodepool.vms.count).to eq(2)
      expect(kubernetes_cluster.reload.all_vms.map(&:id)).to eq((kubernetes_cluster.cp_vms + kubernetes_nodepool.vms).map(&:id))

      mock_sshable = instance_double(Sshable)
      expect(kubernetes_cluster.all_vms).to all(receive(:sshable).and_return(mock_sshable))
      expect(mock_sshable).to receive(:cmd).with("sudo sed -i 's/9\\.9\\.9\\.9/7\\.7\\.7\\.7/g' /etc/hosts").exactly(4).times

      expect(prog.old_vm).to receive(:sshable).and_return(mock_sshable)
      expect(mock_sshable).to receive(:cmd).with("sudo kubeadm reset --force")
    end

    it "updates the /etc/hosts file and destroys the old node" do
      expect(kubernetes_cluster).to receive(:kubectl).with("delete node #{prog.old_vm.inhost_name}")
      expect(prog.old_vm).to receive(:incr_destroy)

      expect { prog.drop_old_node }.to exit({"msg" => "upgraded node"})
    end

    it "removes the old node from the CP if there is no nodepool given" do
      expect(prog.kubernetes_nodepool).to be_nil
      expect(kubernetes_cluster).to receive(:kubectl).with("delete node #{prog.old_vm.inhost_name}")
      expect(kubernetes_cluster).to receive(:remove_cp_vm).with(prog.old_vm)
      expect(prog.old_vm).to receive(:incr_destroy)

      expect { prog.drop_old_node }.to exit({"msg" => "upgraded node"})
    end

    it "removes the old node from the nodepool if there is one given" do
      allow(prog).to receive(:frame).and_return({"old_vm_id" => prog.old_vm.id, "new_vm_id" => prog.new_vm.id, "nodepool_id" => kubernetes_nodepool.id})
      expect(prog.kubernetes_nodepool).not_to be_nil

      expect(kubernetes_cluster).to receive(:kubectl).with("delete node #{prog.old_vm.inhost_name}")
      expect(prog.kubernetes_nodepool).to receive(:remove_vm).with(prog.old_vm)
      expect(prog.old_vm).to receive(:incr_destroy)

      expect { prog.drop_old_node }.to exit({"msg" => "upgraded node"})
    end

    it "swallows the error if the node is not found" do
      expect(kubernetes_cluster).to receive(:kubectl).with("delete node #{prog.old_vm.inhost_name}").and_raise(
        Sshable::SshError.new("kubeadm", "", "nodes \"#{prog.old_vm.inhost_name}\" not found", 1, nil)
      )
      expect(prog.old_vm).to receive(:incr_destroy)

      expect { prog.drop_old_node }.to exit({"msg" => "upgraded node"})
    end

    it "raises if the error of delete node command is unexpected" do
      expect(kubernetes_cluster).to receive(:kubectl).with("delete node #{prog.old_vm.inhost_name}").and_raise(
        Sshable::SshError.new("kubeadm", "", "some other message", 1, nil)
      )
      expect(prog.old_vm).not_to receive(:incr_destroy)
      expect { prog.drop_old_node }.to raise_error(Sshable::SshError)
    end
  end
end
