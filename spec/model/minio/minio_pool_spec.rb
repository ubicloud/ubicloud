# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MinioPool do
  subject(:mp) {
    mc = MinioCluster.create_with_id(
      location: "hetzner-hel1",
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      target_total_storage_size_gib: 100,
      target_total_pool_count: 1,
      target_total_server_count: 1,
      target_total_driver_count: 1,
      target_vm_size: "standard-2"
    )
    mp = described_class.create_with_id(
      cluster_id: mc.id,
      start_index: 0
    )
    vm = Vm.create_with_id(unix_user: "u", public_key: "k", name: "n", location: "l", boot_image: "i", family: "f", cores: 2)

    MinioServer.create_with_id(
      minio_pool_id: mp.id,
      vm_id: vm.id,
      index: 0
    )
    mp
  }

  describe "#volumes_url" do
    it "returns volumes url properly for a single drive single server pool" do
      expect(mp.volumes_url).to eq("http://minio-cluster-name{0...0}.storage.ubicloud.com:9000/minio/dat{1...1}")
    end

    it "returns volumes url properly for a multi drive single server pool" do
      mp.cluster.update(target_total_driver_count: 4)
      expect(mp.volumes_url).to eq("http://minio-cluster-name{0...0}.storage.ubicloud.com:9000/minio/dat{1...4}")
    end

    it "returns volumes url properly for a multi drive multi server pool" do
      mp.cluster.update(target_total_driver_count: 4, target_total_server_count: 2)
      expect(mp.volumes_url).to eq("http://minio-cluster-name{0...1}.storage.ubicloud.com:9000/minio/dat{1...2}")
    end
  end

  it "returns name properly" do
    expect(mp.name).to eq("minio-cluster-name-0")
  end

  it "returns per server driver count properly" do
    expect(mp.cluster).to receive(:per_pool_driver_count).and_return(4)
    expect(mp.cluster).to receive(:per_pool_server_count).and_return(2)
    expect(mp.per_server_driver_count).to eq(2)
  end

  it "returns per server storage size properly" do
    expect(mp.cluster).to receive(:per_pool_storage_size).and_return(500)
    expect(mp.cluster).to receive(:per_pool_server_count).and_return(2)
    expect(mp.per_server_storage_size).to eq(250)
  end

  it "returns servers in ordered way" do
    mp.cluster.update(target_total_driver_count: 4, target_total_server_count: 2)
    vm = Vm.create_with_id(unix_user: "u", public_key: "k", name: "n", location: "l", boot_image: "i", family: "f", cores: 2)

    MinioServer.create_with_id(
      minio_pool_id: mp.id,
      vm_id: vm.id,
      index: 2
    )

    expect(mp.servers.map(&:index)).to eq([0, 2])
  end
end
