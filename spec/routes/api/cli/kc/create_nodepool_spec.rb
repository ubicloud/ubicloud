# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli kc create-nodepool" do
  before do
    expect(Config).to receive(:kubernetes_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "creates a nodepool on a running cluster" do
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v #{Option.selectable_kubernetes_versions.first}])
    kc = KubernetesCluster.first(name: "test-kc")
    kc.strand.update(label: "wait")
    kc.nodepools.first.strand.update(label: "wait")

    body = cli(%w[kc eu-central-h1/test-kc create-nodepool np2 standard-2 2])

    kn = kc.nodepools_dataset.first(name: "np2")
    expect(body).to eq "Kubernetes nodepool created with id: #{kn.ubid}\n"
    expect(kn.node_count).to eq 2
    expect(kn.target_node_size).to eq "standard-2"
    expect(kn.version).to eq kc.version
    expect(kn.start_bootstrapping_set?).to be true
  end
end
