# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::KubernetesNodepool do
  describe ".serialize_internal" do
    it "serializes a KubernetesNodepool without the detailed option" do
      project = Project.create(name: "default")
      subnet = PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
      kc = KubernetesCluster.create(
        name: "cluster",
        version: "v1.32",
        cp_node_count: 3,
        private_subnet_id: subnet.id,
        location_id: Location::HETZNER_FSN1_ID,
        project_id: project.id,
        target_node_size: "standard-2"
      )
      kn = KubernetesNodepool.create(name: "nodepool", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")

      expected_result = {
        id: kn.ubid,
        name: "nodepool",
        kubernetes_cluster_id: kc.ubid,
        node_count: 2,
        node_size: "standard-2"
      }

      expect(described_class.serialize_internal(kn)).to eq(expected_result)
    end
  end
end
