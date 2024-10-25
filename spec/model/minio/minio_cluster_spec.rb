# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MinioCluster do
  subject(:mc) {
    mc = described_class.create_with_id(
      location: "hetzner-fsn1",
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      root_cert_1: "root_cert_1",
      root_cert_2: "root_cert_2"
    )
    mp = MinioPool.create_with_id(
      cluster_id: mc.id,
      start_index: 0,
      server_count: 1,
      drive_count: 1,
      storage_size_gib: 100,
      vm_size: "standard-2"
    )

    MinioServer.create_with_id(
      minio_pool_id: mp.id,
      vm_id: create_vm.id,
      index: 0
    )
    mc
  }

  it "generates /etc/hosts entries properly when there are multiple pool" do
    server = mc.servers.first
    expect(mc).to receive(:servers).and_return([server, server]).at_least(:once)
    expect(server).to receive(:hostname).and_return("hostname").at_least(:once)
    expect(server).to receive(:private_ipv4_address).and_return("10.0.0.0").at_least(:once)

    expect(mc.generate_etc_hosts_entry).to eq("10.0.0.0 hostname\n10.0.0.0 hostname")
  end

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
    expect(mc.servers.first.vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
    expect(mc.ip4_urls).to eq(["https://1.1.1.1:9000"])
  end

  it "returns hyper tag name properly" do
    project = instance_double(Project, ubid: "project-ubid")
    expect(mc.hyper_tag_name(project)).to eq("project/project-ubid/location/eu-central-h1/minio-cluster/minio-cluster-name")
  end
end
