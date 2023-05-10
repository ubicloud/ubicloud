# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MinioNode do
  subject(:node) do
    node = described_class.create(pool_id: pool.id)
    Vm.create(public_key: "key", unix_user: "ubi", name: "test",
      size: "m5a.2x", location: "hetzner-hel1", boot_image: "ubuntu-jammy") { _1.id = node.id }
    node
  end

  let(:cluster) { MinioCluster.create(name: "test", capacity: 100) }
  let(:pool) { MinioPool.create(cluster_id: cluster.id, capacity: 100, node_count: 1, start_index: 1) }

  describe "minio_node" do
    it "finds node index" do
      expect(node.index).to eq(1)
    end

    it "finds node address" do
      expect(node.good_address).to eq("test1.#{Config.minio_host_name}")
    end

    it "finds node name" do
      expect(node.name).to eq("test1")
    end
  end
end
