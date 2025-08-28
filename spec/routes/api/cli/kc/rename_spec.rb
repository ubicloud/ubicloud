# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli kc rename" do
  it "renames kubernetes cluster" do
    expect(Config).to receive(:kubernetes_service_project_id).and_return(@project.id).at_least(:once)
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v #{Option.kubernetes_versions.first}])
    expect(cli(%W[kc eu-central-h1/test-kc rename new-name])).to eq "Kubernetes cluster renamed to new-name\n"
    expect(KubernetesCluster.select_order_map(:name)).to eq ["new-name"]
  end
end
