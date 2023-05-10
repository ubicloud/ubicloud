# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MinioPool do
  subject(:pool) { described_class.new(cluster_id: cluster.id, capacity: 100, node_count: node_count, start_index: start_index) }

  let(:cluster) { MinioCluster.create(name: "test", capacity: 100) }
  let(:nodes) do
    Array.new(node_count) do |i|
      vm = Vm.create(public_key: "key", unix_user: "ubi", name: "test" + i.to_s,
        size: "m5a.2x", location: "hetzner-hel1", boot_image: "ubuntu-jammy")
      vm.ephemeral_net6 = "2001:db8:1::#{i}"
      vm.save_changes
      MinioNode.create(pool_id: pool.id) { _1.id = vm.id }
    end
  end
  let(:node_count) { 5 }
  let(:start_index) { 3 }

  describe "minio_pool" do
    it "ipv6s are listed properly according to creation time" do
      pool.save_changes
      nodes.map(&:reload)
      expect(pool.minio_node.map(&:id).sort).to eq(nodes.map(&:id).sort)
      expect(pool.node_ipv6_sorted_by_creation.sort).to eq(["2001:db8:1::/128", "2001:db8:1::1/128", "2001:db8:1::2/128", "2001:db8:1::3/128", "2001:db8:1::4/128"])
    end
  end
end
