# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::KubernetesNodepool do
  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

  describe ".serialize_internal" do
    it "serializes a KubernetesNodepool with the detailed option" do
      project = Project.create(name: "default")
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "cluster", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, version: Option.selectable_kubernetes_versions.first).subject
      kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "nodepool", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
      vm = create_vm
      KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)

      expected_result = {
        id: kn.ubid,
        name: "nodepool",
        kubernetes_cluster_id: kc.ubid,
        node_count: 2,
        node_size: "standard-2",
        version: kc.version,
        vms: Serializers::Vm.serialize([vm]),
      }

      expect(described_class.serialize_internal(kn, {detailed: true})).to eq(expected_result)
    end

    it "serializes a KubernetesNodepool without the detailed option" do
      project = Project.create(name: "default")
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "cluster", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, version: Option.selectable_kubernetes_versions.first).subject
      kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "nodepool", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject

      expected_result = {
        id: kn.ubid,
        name: "nodepool",
        kubernetes_cluster_id: kc.ubid,
        node_count: 2,
        node_size: "standard-2",
        version: kc.version,
      }

      expect(described_class.serialize_internal(kn)).to eq(expected_result)
    end
  end
end
