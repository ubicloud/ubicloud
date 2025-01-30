# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesCluster do
  subject(:kc) {
    described_class.new(
      name: "kc-name",
      version: "v1.32",
      location: "hetzner-fsn1",
      cp_node_count: 3,
      project_id: "2d720de2-91fc-82d2-bc07-a945bddb39e8",
      private_subnet_id: "c87aefff-2e77-86d9-86b5-ef9fbb4e7fee",
      target_node_size: "standard-2"
    )
  }

  it "displays location properly" do
    expect(kc.display_location).to eq("eu-central-h1")
  end

  it "returns path" do
    expect(kc.path).to eq("/location/eu-central-h1/kubernetes-cluster/kc-name")
  end

  describe "#validate" do
    it "validates cp_node_count" do
      kc.cp_node_count = 0
      expect(kc.valid?).to be false
      expect(kc.errors[:cp_node_count]).to eq(["must be greater than 0"])

      kc.cp_node_count = 2
      expect(kc.valid?).to be true
    end

    it "validates version" do
      kc.version = "v1.33"
      expect(kc.valid?).to be false
      expect(kc.errors[:version]).to eq(["must be a valid Kubernetes version"])

      kc.version = "v1.32"
      expect(kc.valid?).to be true
    end
  end
end
