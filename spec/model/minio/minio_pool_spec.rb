# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MinioPool do
  subject(:mp) {
    mc = MinioCluster.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      root_cert_1: "dummy-root-cert-1",
      root_cert_2: "dummy-root-cert-2",
      project_id: Project.create(name: "test").id
    )
    mp = described_class.create(
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
    mp
  }

  describe "#volumes_url" do
    it "returns volumes url properly for a single drive single server pool" do
      expect(mp.volumes_url).to eq("/minio/dat1")
    end

    it "returns volumes url properly for a multi drive single server pool" do
      mp.update(drive_count: 4)
      expect(mp.volumes_url).to eq("/minio/dat{1...4}")
    end

    it "returns volumes url properly for a multi drive multi server pool" do
      mp.update(drive_count: 4, server_count: 2)
      expect(mp.volumes_url).to eq("https://minio-cluster-name{0...1}.minio.ubicloud.com:9000/minio/dat{1...2}")
    end
  end

  it "returns name properly" do
    expect(mp.name).to eq("minio-cluster-name-0")
  end

  it "returns per server driver count properly" do
    expect(mp).to receive(:drive_count).and_return(4)
    expect(mp).to receive(:server_count).and_return(2)
    expect(mp.per_server_drive_count).to eq(2)
  end

  it "returns per server storage size properly" do
    expect(mp).to receive(:storage_size_gib).and_return(500)
    expect(mp).to receive(:server_count).and_return(2)
    expect(mp.per_server_storage_size).to eq(250)
  end

  it "returns servers in ordered way" do
    mp.update(drive_count: 4, server_count: 2)

    MinioServer.create(
      minio_pool_id: mp.id,
      vm_id: create_vm.id,
      index: 2
    )

    expect(mp.servers.map(&:index)).to eq([0, 2])
  end
end
