# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe KubernetesNodepool do
  subject(:kn) { Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject }

  let(:project) { Project.create(name: "test") }
  let(:kc) { Prog::Kubernetes::KubernetesClusterNexus.assemble(name: "kc-name", version: Option.selectable_kubernetes_versions.first, location_id: Location::HETZNER_FSN1_ID, cp_node_count: 3, project_id: project.id, target_node_size: "standard-2").subject }

  before {
    allow(Config).to receive(:kubernetes_service_project_id).and_return(project.id)
  }

  describe "#destroying?" do
    it "is true while the destroy semaphore is set or the strand is in destroy" do
      expect(kn.destroying?).to be false

      kn.incr_destroy
      expect(kn.reload.destroying?).to be true

      Semaphore.where(strand_id: kn.id, name: "destroy").destroy
      kn.strand.update(label: "destroy")
      expect(kn.reload.destroying?).to be true
    end
  end

  describe "#upgrading?" do
    it "is true while the strand is in an upgrade label or the upgrade semaphore is set" do
      kn.strand.update(label: "wait")
      expect(kn.upgrading?).to be false

      kn.strand.update(label: "upgrade")
      expect(kn.reload.upgrading?).to be true

      kn.strand.update(label: "wait_upgrade")
      expect(kn.reload.upgrading?).to be true

      kn.strand.update(label: "wait")
      kn.incr_upgrade
      expect(kn.reload.upgrading?).to be true
    end
  end

  describe "#display_state" do
    it "reflects the nodepool state" do
      expect(kn.display_state).to eq "creating"

      kn.strand.update(label: "wait")
      expect(kn.reload.display_state).to eq "running"

      kn.incr_scale_worker_count
      expect(kn.reload.display_state).to eq "resizing"

      kn.strand.update(label: "bootstrap_worker_nodes")
      expect(kn.reload.display_state).to eq "resizing"
      Semaphore.where(strand_id: kn.id, name: "scale_worker_count").destroy
      kn.strand.update(label: "wait")

      kn.incr_upgrade_requested
      expect(kn.reload.display_state).to eq "upgrading"
      Semaphore.where(strand_id: kn.id, name: "upgrade_requested").destroy

      kn.strand.update(label: "wait_upgrade")
      expect(kn.reload.display_state).to eq "upgrading"

      kn.strand.update(label: "destroy")
      expect(kn.reload.display_state).to eq "deleting"

      kn.strand.update(label: "wait")
      kn.incr_destroy
      expect(kn.reload.display_state).to eq "deleting"
    end
  end

  describe "#available_upgrade_version" do
    it "is the cluster version while the nodepool lags behind it" do
      versions = Option.kubernetes_versions
      expect(kn.available_upgrade_version).to be_nil

      kn.update(version: versions[2])
      expect(kn.available_upgrade_version).to eq(versions[0])

      kn.update(version: versions[1])
      expect(kn.available_upgrade_version).to eq(versions[0])
    end
  end

  describe "#ready_for_upgrade?" do
    it "is true only when the nodepool is behind the cluster version and the whole cluster is idle" do
      kc.strand.update(label: "wait")
      kn.strand.update(label: "wait")
      Semaphore.where(strand_id: kn.id, name: "start_bootstrapping").destroy
      expect(kn.reload.ready_for_upgrade?).to be false

      kn.update(version: Option.kubernetes_versions[1])
      expect(kn.reload.ready_for_upgrade?).to be true

      kc.strand.update(label: "upgrade")
      expect(kn.reload.ready_for_upgrade?).to be false

      kc.strand.update(label: "wait")
      kn.strand.update(label: "bootstrap_worker_nodes")
      expect(kn.reload.ready_for_upgrade?).to be false

      kn.strand.update(label: "wait")
      np2 = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np2", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
      Semaphore.where(strand_id: np2.id, name: "start_bootstrapping").destroy
      np2.strand.update(label: "upgrade")
      expect(kn.reload.ready_for_upgrade?).to be false

      np2.strand.update(label: "wait")
      kn.incr_upgrade
      expect(kn.reload.ready_for_upgrade?).to be false

      Semaphore.where(strand_id: kn.id, name: "upgrade").destroy
      kn.incr_scale_worker_count
      expect(kn.reload.ready_for_upgrade?).to be false

      Semaphore.where(strand_id: kn.id, name: "scale_worker_count").destroy
      kc.incr_sync_kubeconfig
      expect(kn.reload.ready_for_upgrade?).to be true
    end
  end
end
