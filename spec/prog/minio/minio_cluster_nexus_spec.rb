# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::MinioClusterNexus do
  subject(:nx) {
    described_class.new(
      described_class.assemble(
        minio_project.id, "minio", "hetzner-hel1", "minio-admin", 100, 1, 1, 1, "standard-2"
      )
    )
  }

  let(:minio_project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

  describe ".assemble" do
    before do
      allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
    end

    it "validates input" do
      expect {
        described_class.assemble(SecureRandom.uuid, "minio", "hetzner-hel1", "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(minio_project.id, "minio", "hetzner-xxx", "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: provider"

      expect {
        described_class.assemble(minio_project.id, "minio/name", "hetzner-hel1", "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(minio_project.id, "minio", "hetzner-hel1", "mu", 100, 1, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: username"
    end

    it "creates a minio cluster" do
      described_class.assemble(minio_project.id, "minio2", "hetzner-hel1", "minio-admin", 100, 1, 1, 1, "standard-2")

      expect(MinioCluster.count).to eq 1
      expect(MinioCluster.first.name).to eq "minio2"
      expect(MinioCluster.first.location).to eq "hetzner-hel1"
      expect(MinioCluster.first.admin_user).to eq "minio-admin"
      expect(MinioCluster.first.admin_password).to match(/^[A-Za-z0-9_-]{20}$/)
      expect(MinioCluster.first.target_total_storage_size_gib).to eq 100
      expect(MinioCluster.first.target_total_pool_count).to eq 1
      expect(MinioCluster.first.target_total_server_count).to eq 1
      expect(MinioCluster.first.target_total_driver_count).to eq 1
      expect(MinioCluster.first.target_vm_size).to eq "standard-2"
      expect(MinioCluster.first.projects).to eq [minio_project]
      expect(MinioCluster.first.strand.label).to eq "start"
    end
  end

  describe "#start" do
    before do
      allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
    end

    it "creates a subnet and minio pools" do
      expect {
        nx.start
      }.to hop("wait_pools")
      expect(nx.minio_cluster.pools.count).to eq 1
      expect(nx.minio_cluster.private_subnet_id).not_to be_nil
    end
  end

  describe "#wait_pools" do
    before do
      st = instance_double(Strand, label: "wait")
      instance_double(MinioPool, strand: st).tap { |mp| allow(nx.minio_cluster).to receive(:pools).and_return([mp]) }
    end

    it "hops to configure_dns_records if all pools are waiting" do
      expect {
        nx.wait_pools
      }.to hop("configure_dns_records")
    end

    it "naps if not all pools are waiting" do
      allow(nx.minio_cluster.pools.first.strand).to receive(:label).and_return("start")
      expect {
        nx.wait_pools
      }.to nap(5)
    end
  end

  describe "#configure_dns_records" do
    it "inserts dns records and hops to wait" do
      dns_zone = instance_double(DnsZone)
      expect(dns_zone).to receive(:insert_record).with(record_name: "minio.minio.ubicloud.com", type: "A", ttl: 10, data: "1.1.1.1")
      ms = instance_double(MinioServer, vm: instance_double(Vm, ephemeral_net4: "1.1.1.1"))
      expect(nx.minio_cluster).to receive(:servers).and_return([ms])
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect {
        nx.configure_dns_records
      }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect {
        nx.wait
      }.to nap(30)
    end
  end

  describe "#destroy" do
    it "increments destroy semaphore of minio pools and hops to wait_pools_destroy" do
      dns_zone = instance_double(DnsZone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "minio.minio.ubicloud.com")
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(nx).to receive(:decr_destroy)
      expect(nx.minio_cluster).to receive(:dissociate_with_project).with(minio_project)
      mp = instance_double(MinioPool, incr_destroy: nil)
      expect(mp).to receive(:incr_destroy)
      expect(nx.minio_cluster).to receive(:pools).and_return([mp])
      expect {
        nx.destroy
      }.to hop("wait_pools_destroyed")
    end
  end

  describe "#wait_pools_destroyed" do
    it "naps if there are still minio pools" do
      expect(nx.minio_cluster).to receive(:pools).and_return([true])
      expect {
        nx.wait_pools_destroyed
      }.to nap(10)
    end

    it "increments destroy semaphore of subnet and minio cluster and pops" do
      expect(nx.minio_cluster).to receive(:destroy)
      expect(nx).to receive(:pop).with("destroyed")
      nx.wait_pools_destroyed
    end

    it "increments private subnet destroy if exists" do
      ps = instance_double(PrivateSubnet)
      expect(ps).to receive(:incr_destroy)
      expect(nx.minio_cluster).to receive(:private_subnet).and_return(ps)
      expect(nx.minio_cluster).to receive(:destroy)
      expect(nx).to receive(:pop).with("destroyed")
      nx.wait_pools_destroyed
    end
  end

  describe "#before_run" do
    it "hops to destroy if destroy is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect {
        nx.before_run
      }.to hop("destroy")
    end

    it "does not hop to destroy if destroy is not set" do
      expect(nx).to receive(:when_destroy_set?).and_return(false)
      expect(nx).not_to receive(:hop_destroy)
      nx.before_run
    end

    it "does not hop to destroy if strand label is destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect(nx).not_to receive(:hop_destroy)
      nx.before_run
    end
  end

  describe "#dns_zone" do
    it "fetches dns zone from database only once" do
      expect(DnsZone).to receive(:where).exactly(:once).and_return([true])

      nx.dns_zone
      nx.dns_zone
    end
  end
end
