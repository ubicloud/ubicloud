# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli kc upgrade-nodepool" do
  before do
    expect(Config).to receive(:kubernetes_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "upgrades a nodepool that is behind the cluster version" do
    cli(%W[kc eu-central-h1/test-kc create -c 1 -z standard-2 -w 1 -v #{Option.selectable_kubernetes_versions.first}])
    kc = KubernetesCluster.first(name: "test-kc")
    kn = kc.nodepools.first
    kn.update(version: Option.kubernetes_versions[1])
    kc.strand.update(label: "wait")
    kn.strand.update(label: "wait")

    body = cli(%w[kc eu-central-h1/test-kc upgrade-nodepool test-kc-np])

    expect(body).to eq "Scheduled version upgrade of nodepool test-kc-np to version #{kn.reload.version}.\n"
    expect(kn.version).to eq Option.kubernetes_versions[0]
    expect(kn.upgrade_requested_set?).to be true
    expect(kc.upgrade_nodepools_set?).to be true
  end
end
