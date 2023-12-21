# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MinioServer do
  subject(:ms) {
    mc = MinioCluster.create_with_id(
      location: "hetzner-hel1",
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      target_total_storage_size_gib: 100,
      target_total_pool_count: 1,
      target_total_server_count: 1,
      target_total_drive_count: 1,
      target_vm_size: "standard-2"
    )
    mp = MinioPool.create_with_id(
      cluster_id: mc.id,
      start_index: 0,
      server_count: 1,
      drive_count: 1,
      storage_size_gib: 100
    )
    vm = Vm.create_with_id(unix_user: "u", public_key: "k", name: "n", location: "l", boot_image: "i", family: "f", cores: 2)

    described_class.create_with_id(
      minio_pool_id: mp.id,
      vm_id: vm.id,
      index: 0
    )
  }

  it "returns hostname properly" do
    expect(ms.hostname).to eq("minio-cluster-name0.minio.ubicloud.com")
  end

  it "returns private ipv4 address properly" do
    nic = instance_double(Nic, private_ipv4: instance_double(NetAddr::IPv4Net, network: "192.168.0.0"))
    expect(ms.vm).to receive(:nics).and_return([nic])
    expect(ms.private_ipv4_address).to eq("192.168.0.0")
  end

  it "returns name properly" do
    expect(ms.name).to eq("minio-cluster-name-0-0")
  end

  it "returns minio cluster properly" do
    expect(ms.cluster.name).to eq("minio-cluster-name")
  end

  describe "#minio_volumes" do
    it "returns minio volumes properly for a single drive single server cluster" do
      expect(ms.minio_volumes).to eq("/minio/dat1")
    end

    it "returns minio volumes properly for a multi drive single server cluster" do
      ms.cluster.update(target_total_drive_count: 4)
      expect(ms.minio_volumes).to eq("/minio/dat{1...4}")
    end

    it "returns minio volumes properly for a multi drive multi server cluster" do
      ms.cluster.update(target_total_drive_count: 4, target_total_server_count: 2)
      ms.pool.update(server_count: 2, drive_count: 4)
      expect(ms.minio_volumes).to eq("http://minio-cluster-name{0...1}.minio.ubicloud.com:9000/minio/dat{1...2}")
    end
  end
end
