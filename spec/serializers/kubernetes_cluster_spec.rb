# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::KubernetesCluster do
  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

  describe ".serialize_internal" do
    it "serializes a KubernetesCluster without the detailed option" do
      project = Project.create(name: "default")
      subnet = PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id)
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "cluster", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, version: "v1.32", private_subnet_id: subnet.id).subject
      kn = KubernetesNodepool.create(name: "nodepool", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)

      expected_result = {
        id: kc.ubid,
        name: "cluster",
        location: "eu-central-h1",
        display_state: "creating",
        cp_node_count: 3,
        node_size: "standard-2",
        version: "v1.32"
      }

      expect(described_class.serialize_internal(kc)).to eq(expected_result)
    end

    it "serializes a KubernetesNodepool without the detailed option" do
      project = Project.create(name: "default")
      subnet = PrivateSubnet.create(net6: "0::0", net4: "127.0.0.1", name: "x", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id)
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "cluster", project_id: project.id, location_id: Location::HETZNER_FSN1_ID, version: "v1.32", private_subnet_id: subnet.id).subject
      kn = KubernetesNodepool.create(name: "nodepool", node_count: 2, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
      cp_vm = create_vm
      KubernetesNode.create(vm_id: cp_vm.id, kubernetes_cluster_id: kc.id)
      KubernetesNode.create(vm_id: create_vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)

      expected_result = {
        id: kc.ubid,
        name: "cluster",
        location: "eu-central-h1",
        display_state: "creating",
        cp_node_count: 3,
        node_size: "standard-2",
        version: "v1.32",
        cp_vms: Serializers::Vm.serialize([cp_vm]),
        nodepools: Serializers::KubernetesNodepool.serialize([kn], {detailed: true})
      }

      expect(described_class.serialize_internal(kc, {detailed: true})).to eq(expected_result)
    end
  end
end
