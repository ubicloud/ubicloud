# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::MinioPoolNexus do
  subject(:nx) { described_class.new(described_class.assemble(minio_cluster.id, 0, 1, 1, 100, "standard-2")) }

  let(:minio_cluster) {
    MinioCluster.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      private_subnet_id: ps.id,
      project_id: minio_project.id
    )
  }
  let(:minio_cluster_strand) { Strand.create_with_id(minio_cluster, prog: "Minio::MinioClusterNexus", label: "wait") }
  let(:ps) {
    Prog::Vnet::SubnetNexus.assemble(minio_project.id, name: "minio-cluster-name", location_id: Location::HETZNER_FSN1_ID)
  }

  let(:minio_project) { Project.create(name: "default") }

  before do
    allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
  end

  describe ".assemble" do
    it "creates a minio pool" do
      st = described_class.assemble(minio_cluster.id, 0, 1, 1, 100, "standard-2")
      expect(MinioPool.count).to eq 1
      expect(st.label).to eq "wait_servers"
      expect(MinioPool.first.cluster).to eq minio_cluster
    end

    it "fails if cluster is not valid" do
      expect {
        described_class.assemble(SecureRandom.uuid, 0, 1, 1, 100, "standard-2")
      }.to raise_error RuntimeError, "No existing cluster"
    end
  end

  describe ".assemble_additional_pool" do
    it "creates a minio pool for an existing cluster" do
      described_class.assemble(minio_cluster.id, 0, 1, 1, 100, "standard-2")
      st = described_class.assemble_additional_pool(minio_cluster.id, 1, 1, 100, "standard-2")
      expect(MinioPool.count).to eq 2
      expect(st.label).to eq "wait_servers"
      expect(st.subject.start_index).to eq 1
    end

    it "fails if cluster is not valid" do
      expect {
        described_class.assemble_additional_pool(SecureRandom.uuid, 0, 1, 100, "standard-2")
      }.to raise_error RuntimeError, "No existing cluster"
    end

    it "correctly calculates start index for additional pool for a cluster with decommissioned pools" do
      described_class.assemble(minio_cluster.id, 2, 2, 2, 100, "standard-2")
      st = described_class.assemble_additional_pool(minio_cluster.id, 1, 1, 100, "standard-2")
      expect(st.subject.start_index).to eq 4
    end
  end

  describe "#wait_servers" do
    it "waits if nothing to do" do
      # Server strand starts at "start", not "wait" - so it waits
      expect { nx.wait_servers }.to nap(5)
    end

    it "hops to wait if all servers are waiting" do
      nx.minio_pool.servers.each { it.strand.update(label: "wait") }
      expect { nx.wait_servers }.to hop("wait")
    end

    it "triggers reconfigure if addition_pool_set" do
      minio_cluster_strand
      nx.minio_pool.servers.each { it.strand.update(label: "wait") }
      nx.incr_add_additional_pool
      expect { nx.wait_servers }.to hop("wait")
      expect(Semaphore.where(strand_id: nx.minio_pool.id, name: "add_additional_pool").count).to eq(0)
      expect(Semaphore.where(strand_id: minio_cluster.id, name: "reconfigure").count).to eq(1)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#destroy" do
    it "increments destroy semaphore of minio servers and hops to wait_servers_destroy" do
      nx.incr_destroy
      server_ids = nx.minio_pool.servers.map(&:id)
      expect { nx.destroy }.to hop("wait_servers_destroyed")
      expect(Semaphore.where(strand_id: nx.minio_pool.id, name: "destroy").count).to eq(0)
      server_ids.each { expect(Semaphore.where(strand_id: it, name: "destroy").count).to eq(1) }
    end
  end

  describe "#wait_servers_destroyed" do
    it "naps if there are still minio servers" do
      # Pool already has servers from assemble
      expect { nx.wait_servers_destroyed }.to nap(5)
    end

    it "pops if all minio servers are destroyed" do
      # Destroy all servers to simulate they're gone
      MinioServer.where(minio_pool_id: nx.minio_pool.id).destroy
      expect { nx.wait_servers_destroyed }.to exit({"msg" => "pool destroyed"})
    end
  end
end
