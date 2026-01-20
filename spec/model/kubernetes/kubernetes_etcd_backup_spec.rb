# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe KubernetesEtcdBackup do
  subject(:keb) do
    described_class.create(
      kubernetes_cluster_id: kc.id,
      access_key: "access",
      secret_key: "secret",
      location_id: location.id
    )
  end

  let(:project) { Project.create(name: "test") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:private_subnet) { PrivateSubnet.create(project_id: project.id, name: "test", location_id: location.id, net6: "fe80::/64", net4: "192.168.0.0/24") }
  let(:kc) {
    kc = KubernetesCluster.create(
      name: "test-cluster",
      version: Option.kubernetes_versions.first,
      location_id: location.id,
      project_id: project.id,
      private_subnet_id: private_subnet.id,
      cp_node_count: 1,
      target_node_size: "standard-2"
    )
    vm = Prog::Vm::Nexus.assemble("public key", project.id, name: "cp", private_subnet_id: kc.private_subnet.id).subject
    Sshable.create_with_id(vm)
    KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id)
    kc
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(project.id)
  end

  describe "#blob_storage" do
    before do
      MinioCluster.create(project_id: project.id, location_id: location.id, name: "minio-cluster", admin_user: "admin", admin_password: "password", root_cert_1: "certs")
    end

    it "returns the minio cluster for the project and location" do
      expect(keb.blob_storage).to eq MinioCluster[name: "minio-cluster"]
    end

    it "memoizes the result" do
      expect(MinioCluster).to receive(:[]).with(project_id: project.id, location_id: location.id).once.and_call_original
      keb.blob_storage
      keb.blob_storage
    end
  end

  describe "#need_backup?" do
    let(:minio_cluster) { MinioCluster.create(project_id: project.id, location_id: location.id, name: "minio-cluster", admin_user: "admin", admin_password: "password", root_cert_1: "certs") }

    before do
      allow(minio_cluster).to receive(:url).and_return("https://minio.test")
    end

    it "returns false if blob storage is nil" do
      expect(keb).to receive(:blob_storage).and_return(nil)
      expect(keb.need_backup?).to be false
    end

    it "returns false if functional nodes are empty" do
      keb.kubernetes_cluster.functional_nodes.each { it.destroy }
      keb.kubernetes_cluster.reload
      expect(keb.need_backup?).to be false
    end

    context "when blob storage is present" do
      let(:sshable) { keb.kubernetes_cluster.functional_nodes.first.vm.sshable }

      it "returns true if backup status is Failed" do
        expect(sshable).to receive(:d_check).with("backup_etcd").and_return("Failed")
        expect(keb.need_backup?).to be true
      end

      it "returns true if backup status is NotStarted" do
        expect(sshable).to receive(:d_check).with("backup_etcd").and_return("NotStarted")
        expect(keb.need_backup?).to be true
      end

      it "returns true if status is Succeeded and no previous backup" do
        expect(sshable).to receive(:d_check).with("backup_etcd").and_return("Succeeded")
        expect(keb.latest_backup_started_at).to be_nil
        expect(keb.need_backup?).to be true
      end

      it "returns true if status is Succeeded and previous backup is old" do
        expect(sshable).to receive(:d_check).with("backup_etcd").and_return("Succeeded")
        keb.update(latest_backup_started_at: Time.now - 3601)
        expect(keb.need_backup?).to be true
      end

      it "returns false if status is Succeeded and previous backup is recent" do
        expect(sshable).to receive(:d_check).with("backup_etcd").and_return("Succeeded")
        keb.update(latest_backup_started_at: Time.now - 3500)
        expect(keb.need_backup?).to be false
      end

      it "returns false if status is unknown" do
        expect(sshable).to receive(:d_check).with("backup_etcd").and_return("Unknown")
        expect(keb.need_backup?).to be false
      end
    end
  end

  describe "#setup_bucket" do
    let(:client) { instance_double(Minio::Client) }

    before do
      allow(keb).to receive(:blob_storage_client).and_return(client)
    end

    it "creates bucket and sets lifecycle policy" do
      expect(client).to receive(:create_bucket).with(keb.ubid)
      expect(client).to receive(:set_lifecycle_policy).with(keb.ubid, keb.ubid, KubernetesEtcdBackup::BACKUP_BUCKET_EXPIRATION_DAYS)
      keb.setup_bucket
    end
  end

  describe "#next_backup_time" do
    it "returns tomorrow if blob_storage is not configured" do
      expect(keb).to receive(:blob_storage).and_return(nil)
      expect(keb.next_backup_time).to be_within(1).of(Time.now + 86400)
    end

    context "when blob storage is configured" do
      let!(:minio_cluster) { MinioCluster.create(project_id: project.id, location_id: location.id, name: "minio-cluster", admin_user: "admin", admin_password: "password", root_cert_1: "certs") }

      before do
        allow(minio_cluster).to receive(:url).and_return("https://minio.test")
      end

      it "returns Time.now if latest_backup_started_at is nil" do
        expect(keb.next_backup_time).to be_within(1).of(Time.now)
      end

      it "returns latest_backup_started_at + 1 hour if latest_backup_started_at is set" do
        time = Time.now
        keb.update(latest_backup_started_at: time)
        expect(keb.next_backup_time).to be_within(1).of(time + 3600)
      end
    end
  end
end
