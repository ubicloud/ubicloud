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
      project_id: Project.create(name: "test").id
    )
    mp = MinioPool.create(
      cluster_id: mc.id,
      start_index: 0,
      server_count: 1,
      drive_count: 1,
      storage_size_gib: 100,
      vm_size: "standard-2"
    )

    MinioServer.create(
      minio_pool_id: mp.id,
      vm_id: create_vm.id,
      index: 0
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
end
