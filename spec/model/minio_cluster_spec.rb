# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe MinioCluster do
  let(:cluster) { described_class.create(name: "test", capacity: 100) }
  let(:node_count) { 3 }
  let(:start_index) { 1 }
  let(:nodes) do
    mp = MinioPool.create(cluster_id: cluster.id, capacity: 100, node_count: node_count, start_index: start_index)
    Array.new(node_count) do |i|
      vm = Vm.create(public_key: "key", unix_user: "ubi", name: "test#{i}",
        size: "m5a.2x", location: "hetzner-hel1", boot_image: "ubuntu-jammy")
      vm.ephemeral_net6 = "2001:db8:#{i+1}::/64"
      vm.save_changes
      MinioNode.create(pool_id: mp.id) { _1.id = vm.id }
    end
  end

  describe "minio_cluster" do
    it "changes to the etc/hosts entry is listed properly" do
      nodes.map(&:reload)
      expect("#{cluster.generate_etc_hosts_entry}\n").to eq(
<<~EOF
2001:db8:1::2 test1.#{Config.minio_host_name}
2001:db8:2::2 test2.#{Config.minio_host_name}
2001:db8:3::2 test3.#{Config.minio_host_name}
EOF
      )
    end
  end
end
