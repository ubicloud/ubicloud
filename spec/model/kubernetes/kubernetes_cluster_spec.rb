# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesCluster do
  subject(:kc) {
    described_class.new(
      name: "kc-name",
      kubernetes_version: "v1.32.0",
      location: "hetzner-fsn1",
      cp_node_count: 3
    ) { _1.id = "3ebf43d3-118a-4af7-87d2-59a3b9bf9116" }
  }

  it "displays location properly" do
    expect(kc.display_location).to eq("eu-central-h1")
  end

  it "returns path" do
    expect(kc.path).to eq("/location/eu-central-h1/kubernetes-cluster/kc-name")
  end

  describe "#kubectl" do
    it "runs the given command on the first VM" do
      vms = [create_vm, create_vm]
      sshable = instance_double(Sshable)
      expect(vms[0]).to receive(:sshable).and_return(sshable)
      allow(kc).to receive(:cp_vms).and_return(vms)
      expect(sshable).to receive(:cmd).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes").and_return("something")
      expect(kc.kubectl("get nodes")).to eq("something")
    end
  end

  describe "#all_vms" do
    it "returns all VMs in the cluster, including CP and worker nodes" do
      expect(kc).to receive(:cp_vms).and_return([1, 2])
      expect(kc).to receive(:kubernetes_nodepools).and_return([instance_double(KubernetesNodepool, vms: [3, 4]), instance_double(KubernetesNodepool, vms: [5, 6])])
      expect(kc.all_vms).to eq([1, 2, 3, 4, 5, 6])
    end
  end
end
