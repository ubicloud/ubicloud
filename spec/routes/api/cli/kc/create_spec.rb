# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli kc create" do
  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

  it "creates kubernetes cluster with minimal options" do
    expect(KubernetesCluster.count).to eq 0
    body = cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v v1.32])
    expect(KubernetesCluster.count).to eq 1
    kc = KubernetesCluster.first
    expect(kc).to be_a KubernetesCluster
    expect(kc.name).to eq "test-kc"
    expect(kc.version).to eq "v1.32"
    expect(body).to eq "Kubernetes cluster created with id: #{kc.ubid}\n"
  end

  it "creates kubernetes cluster without --cp-node-count" do
    expect(KubernetesCluster.count).to eq 0
    body = cli(%W[kc eu-central-h1/test-kc create -z standard-2 -w 1 -v v1.32])
    expect(KubernetesCluster.count).to eq 1
    kc = KubernetesCluster.first
    expect(kc).to be_a KubernetesCluster
    expect(kc.name).to eq "test-kc"
    expect(kc.cp_node_count).to eq 1
    expect(kc.version).to eq "v1.32"
    expect(body).to eq "Kubernetes cluster created with id: #{kc.ubid}\n"
  end

  it "creates kubernetes cluster without --worker-node-count" do
    expect(KubernetesCluster.count).to eq 0
    body = cli(%W[kc eu-central-h1/test-kc create -c 3 -z standard-2 -v v1.32])
    expect(KubernetesCluster.count).to eq 1
    kc = KubernetesCluster.first
    expect(kc).to be_a KubernetesCluster
    expect(kc.name).to eq "test-kc"
    expect(kc.cp_node_count).to eq 3
    expect(kc.nodepools.sum(&:node_count)).to eq 1
    expect(kc.version).to eq "v1.32"
    expect(body).to eq "Kubernetes cluster created with id: #{kc.ubid}\n"
  end

  it "creates kubernetes cluster with all options" do
    expect(KubernetesCluster.count).to eq 0
    body = cli(%W[kc eu-central-h1/test-kc create -c 3 -w 2 -z standard-2 -v v1.33])
    expect(KubernetesCluster.count).to eq 1
    kc = KubernetesCluster.first
    expect(kc).to be_a KubernetesCluster
    expect(kc.name).to eq "test-kc"
    expect(kc.cp_node_count).to eq 3
    expect(kc.version).to eq "v1.33"
    expect(body).to eq "Kubernetes cluster created with id: #{kc.ubid}\n"
  end
end
