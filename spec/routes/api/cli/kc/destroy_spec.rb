# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli kc destroy" do
  before do
    expect(Config).to receive(:kubernetes_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "destroys kubernetes cluster" do
    expect(KubernetesCluster.count).to eq 0
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v v1.32])
    expect(KubernetesCluster.count).to eq 1
    kc = KubernetesCluster.first
    expect(Semaphore.where(strand_id: kc.id, name: "destroy")).to be_empty
    expect(cli(%w[kc eu-central-h1/test-kc destroy -f])).to eq "Kubernetes cluster, if it exists, is now scheduled for destruction\n"
    expect(Semaphore.where(strand_id: kc.id, name: "destroy")).not_to be_empty
  end
end
