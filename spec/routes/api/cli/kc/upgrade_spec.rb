# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli kc upgrade" do
  before do
    expect(Config).to receive(:kubernetes_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "upgrades cluster when upgrade is available" do
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v #{Option.selectable_kubernetes_versions.last}])

    body = cli(%w[kc eu-central-h1/test-kc upgrade])

    kc = KubernetesCluster.first(name: "test-kc")
    expect(body).to eq "Scheduled version upgrade of Kubneretes cluster with id #{kc.ubid} to version #{kc.version}.\n"
  end
end
