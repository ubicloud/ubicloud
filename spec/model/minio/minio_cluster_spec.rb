# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MinioCluster do
  subject(:mc) {
    mc = described_class.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      root_cert_1: "root_cert_1",
      root_cert_2: "root_cert_2",
      project_id: Project.create(name: "test").id,
    )
    mp = MinioPool.create(
      cluster_id: mc.id,
      start_index: 0,
      server_count: 1,
      drive_count: 1,
      storage_size_gib: 100,
      vm_size: "standard-2",
    )

    MinioServer.create(
      minio_pool_id: mp.id,
      vm_id: create_vm.id,
      index: 0,
    )
    mc
  }

  it "returns minio servers properly" do
    expect(mc.servers.map(&:index)).to eq([0])
  end

  it "returns per pool storage size properly" do
    expect(mc.storage_size_gib).to eq(100)
  end

  it "returns per pool server count properly" do
    expect(mc.server_count).to eq(1)
  end

  it "returns per pool driver count properly" do
    expect(mc.drive_count).to eq(1)
  end

  it "returns connection strings properly" do
    expect(mc.servers.first.vm).to receive(:ip4).and_return("1.1.1.1")
    expect(mc.ip4_urls).to eq(["https://1.1.1.1:9000"])
  end

  describe "certificates" do
    it "does not use publicly signed certificates for self-signed clusters" do
      expect(mc.uses_publicly_signed_certificates?).to be false
      expect(mc.hostname).to eq "minio-cluster-name.#{Config.minio_host_name}"
      expect(mc.root_certs).to eq "root_cert_1root_cert_2"
    end

    context "with acme and a dns zone configured, and no self-signed root" do
      before do
        allow(Config).to receive_messages(acme_email: "test@ubicloud.com", minio_service_project_id: mc.project_id)
        DnsZone.create(project_id: mc.project_id, name: Config.minio_host_name)
        mc.update(root_cert_1: nil, root_cert_2: nil)
      end

      it "uses publicly signed certificates with an empty CA bundle" do
        expect(mc.uses_publicly_signed_certificates?).to be true
        expect(mc.hostname).to eq "minio-cluster-name.#{Config.minio_host_name}"
        expect(mc.root_certs).to eq ""
      end
    end
  end
end
