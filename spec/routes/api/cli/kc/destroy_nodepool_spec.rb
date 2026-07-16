# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli kc destroy-nodepool" do
  before do
    expect(Config).to receive(:kubernetes_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "destroys a nodepool" do
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v #{Option.selectable_kubernetes_versions.first}])
    kc = KubernetesCluster.first(name: "test-kc")
    kn2 = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np2", node_count: 1, kubernetes_cluster_id: kc.id).subject

    expect(cli(%w[kc eu-central-h1/test-kc destroy-nodepool -f np2])).to eq "Nodepool, if it exists, is now scheduled for destruction\n"
    expect(kn2.destroy_set?).to be true
  end
end
