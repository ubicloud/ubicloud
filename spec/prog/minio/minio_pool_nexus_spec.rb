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
  let(:ps) {
    Prog::Vnet::SubnetNexus.assemble(minio_project.id, name: "minio-cluster-name", location_id: Location::HETZNER_FSN1_ID)
  }

  let(:minio_project) { Project.create(name: "default") }

  before do
    allow(minio_cluster).to receive(:project).and_return(minio_project)
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
      st = instance_double(Strand, label: "wait_servers")
      ms = instance_double(MinioServer, strand: st)
      expect(nx.minio_pool).to receive(:servers).and_return([ms])
      expect { nx.wait_servers }.to nap(5)
    end

    it "hops to wait if all servers are waiting" do
      st = instance_double(Strand, label: "wait")
      ms = instance_double(MinioServer, strand: st)
      expect(nx.minio_pool).to receive(:servers).and_return([ms])
      expect { nx.wait_servers }.to hop("wait")
    end

    it "triggers reconfigure if addition_pool_set" do
      st = instance_double(Strand, label: "wait")
      ms = instance_double(MinioServer, strand: st)
      expect(nx.minio_pool).to receive(:servers).and_return([ms])
      expect(nx).to receive(:when_add_additional_pool_set?).and_yield
      expect(nx.minio_pool.cluster).to receive(:incr_reconfigure)
      expect(nx).to receive(:decr_add_additional_pool)
      expect { nx.wait_servers }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#destroy" do
    it "increments destroy semaphore of minio servers and hops to wait_servers_destroy" do
      expect(nx).to receive(:decr_destroy)
      ms = instance_double(MinioServer)
      expect(ms).to receive(:incr_destroy)
      expect(nx.minio_pool).to receive(:servers).and_return([ms])
      expect { nx.destroy }.to hop("wait_servers_destroyed")
    end
  end

  describe "#wait_servers_destroyed" do
    it "naps if there are still minio servers" do
      expect(nx.minio_pool).to receive(:servers).and_return([true])
      expect { nx.wait_servers_destroyed }.to nap(5)
    end

    it "pops if all minio servers are destroyed" do
      expect(nx.minio_pool).to receive(:servers).and_return([])
      expect(nx.minio_pool).to receive(:destroy)

      expect { nx.wait_servers_destroyed }.to exit({"msg" => "pool destroyed"})
    end
  end

  describe "#before_run" do
    it "hops to destroy if strand is not destroy" do
      st = described_class.assemble(minio_cluster.id, 0, 1, 1, 100, "standard-2")
      st.update(label: "start")
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if strand is destroy" do
      st = described_class.assemble(minio_cluster.id, 0, 1, 1, 100, "standard-2")
      st.update(label: "destroy")
      expect { nx.before_run }.not_to hop("destroy")
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
