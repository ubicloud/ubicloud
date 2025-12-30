# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::MinioClusterNexus do
  subject(:nx) {
    expect(Config).to receive(:minio_service_project_id).and_return(minio_project.id).at_least(:once)
    described_class.new(
      described_class.assemble(
        minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2"
      )
    )
  }

  let(:minio_project) { Project.create(name: "default") }

  describe ".assemble" do
    before do
      allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
    end

    it "validates input" do
      expect {
        described_class.assemble(SecureRandom.uuid, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(minio_project.id, "minio/name", nil, "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error RuntimeError, "No existing location"

      expect {
        described_class.assemble(minio_project.id, "minio/name", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "mu", 100, 1, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: username"

      expect {
        described_class.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 2, 1, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: server_count"

      expect {
        described_class.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 100, 2, 2, 1, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: drive_count"

      expect {
        described_class.assemble(minio_project.id, "minio", Location::HETZNER_FSN1_ID, "minio-admin", 1, 2, 2, 4, "standard-2")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: storage_size_gib"
    end

    it "creates a minio cluster" do
      described_class.assemble(minio_project.id, "minio2", Location::HETZNER_FSN1_ID, "minio-admin", 100, 1, 1, 1, "standard-2")

      expect(MinioCluster.count).to eq 1
      expect(MinioCluster.first.name).to eq "minio2"
      expect(MinioCluster.first.location.name).to eq "hetzner-fsn1"
      expect(MinioCluster.first.admin_user).to eq "minio-admin"
      expect(MinioCluster.first.admin_password).to match(/^[A-Za-z0-9_-]{20}$/)
      expect(MinioCluster.first.storage_size_gib).to eq 100
      expect(MinioCluster.first.pools.count).to eq 1
      expect(MinioCluster.first.server_count).to eq 1
      expect(MinioCluster.first.drive_count).to eq 1
      expect(MinioCluster.first.pools.first.vm_size).to eq "standard-2"
      expect(MinioCluster.first.project).to eq minio_project
      expect(MinioCluster.first.strand.label).to eq "wait_pools"
    end
  end

  describe "#wait_pools" do
    it "hops to wait if all pools are waiting" do
      # Pool strands start at "wait_servers", so need to set them to "wait"
      nx.minio_cluster.pools.each { it.strand.update(label: "wait") }
      expect { nx.wait_pools }.to hop("wait")
    end

    it "naps if not all pools are waiting" do
      # Pool strands start at "wait_servers", not "wait" - so it naps
      expect { nx.wait_pools }.to nap(5)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to reconfigure if reconfigure is set" do
      expect(nx).to receive(:when_reconfigure_set?).and_yield
      expect { nx.wait }.to hop("reconfigure")
    end

    it "hops to refresh_certificates if certificate_last_checked_at is before 1 month" do
      expect(nx.minio_cluster).to receive(:certificate_last_checked_at).and_return(Time.now - 60 * 60 * 24 * 30 - 1)
      expect { nx.wait }.to hop("refresh_certificates")
    end
  end

  describe "#refresh_certificates" do
    it "moves root_cert_2 to root_cert_1 and creates new root_cert_2 if root_cert_1 is about to expire, also updates server_cert" do
      rc2 = nx.minio_cluster.root_cert_2
      rck2 = nx.minio_cluster.root_cert_key_2
      certificate_last_checked_at = nx.minio_cluster.certificate_last_checked_at
      server_ids = nx.minio_cluster.servers.map(&:id)
      expect(OpenSSL::X509::Certificate).to receive(:new).with(nx.minio_cluster.root_cert_1).and_call_original
      expect(Time).to receive(:now).and_return(Time.now + 60 * 60 * 24 * 335 * 5 + 1).at_least(:once)
      expect(Util).to receive(:create_root_certificate).with(common_name: "#{nx.minio_cluster.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10).and_return(["cert", "key"])

      expect { nx.refresh_certificates }.to hop("wait")
      expect(nx.minio_cluster.root_cert_1).to eq rc2
      expect(nx.minio_cluster.root_cert_key_1).to eq rck2
      expect(nx.minio_cluster.root_cert_2).to eq "cert"
      expect(nx.minio_cluster.root_cert_key_2).to eq "key"
      expect(nx.minio_cluster.certificate_last_checked_at).to be > certificate_last_checked_at
      server_ids.each { expect(Semaphore.where(strand_id: it, name: "reconfigure").count).to eq(1) }
    end

    it "doesn't update root_certs if they are not close to expire" do
      rc1 = nx.minio_cluster.root_cert_1
      rck1 = nx.minio_cluster.root_cert_key_1
      rc2 = nx.minio_cluster.root_cert_2
      rck2 = nx.minio_cluster.root_cert_key_2
      certificate_last_checked_at = nx.minio_cluster.certificate_last_checked_at

      expect(OpenSSL::X509::Certificate).to receive(:new).with(nx.minio_cluster.root_cert_1).and_call_original

      expect { nx.refresh_certificates }.to hop("wait")
      expect(nx.minio_cluster.root_cert_1).to eq rc1
      expect(nx.minio_cluster.root_cert_key_1).to eq rck1
      expect(nx.minio_cluster.root_cert_2).to eq rc2
      expect(nx.minio_cluster.root_cert_key_2).to eq rck2
      expect(nx.minio_cluster.certificate_last_checked_at).to be > certificate_last_checked_at
    end
  end

  describe "#reconfigure" do
    it "increments reconfigure semaphore of all minio servers and hops to wait" do
      expect(nx).to receive(:decr_reconfigure)
      server_ids = nx.minio_cluster.servers.map(&:id)
      expect { nx.reconfigure }.to hop("wait")
      server_ids.each do |id|
        expect(Semaphore.where(strand_id: id, name: "reconfigure").count).to eq(1)
        expect(Semaphore.where(strand_id: id, name: "restart").count).to eq(1)
      end
    end
  end

  describe "#destroy" do
    it "increments destroy semaphore of minio pools and hops to wait_pools_destroy" do
      expect(nx).to receive(:decr_destroy)
      pool_ids = nx.minio_cluster.pools.map(&:id)
      expect { nx.destroy }.to hop("wait_pools_destroyed")
      pool_ids.each { expect(Semaphore.where(strand_id: it, name: "destroy").count).to eq(1) }
    end
  end

  describe "#wait_pools_destroyed" do
    it "naps if there are still minio pools" do
      # Pool already exists from assemble
      expect { nx.wait_pools_destroyed }.to nap(10)
    end

    it "increments private subnet destroy and destroys minio cluster" do
      cluster_id = nx.minio_cluster.id
      # Capture references before deleting to avoid loading association into cache
      private_subnet = nx.minio_cluster.private_subnet
      private_subnet_id = private_subnet.id
      # Destroy servers first (FK constraint), then pools
      MinioServer.where(minio_pool_id: MinioPool.where(cluster_id:).select(:id)).destroy
      MinioPool.where(cluster_id:).destroy
      expect { nx.wait_pools_destroyed }.to exit({"msg" => "destroyed"})
      expect(private_subnet.firewalls_dataset.count).to eq 0
      expect(Semaphore.where(strand_id: private_subnet_id, name: "destroy").count).to eq(1)
    end
  end

  describe "#before_run" do
    it "hops to destroy if destroy is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if destroy is not set" do
      expect(nx).to receive(:when_destroy_set?).and_return(false)
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if strand label is destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end
end
