# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::MinioCluster do
  subject(:minio_test) { described_class.new(described_class.assemble(project_id)) }

  let(:project_id) { "546a1ed8-53e5-86d2-966c-fb782d2ae3ab" }
  let(:minio_service_project_id) { "f7207bf6-a031-4c98-aee6-4bb9cb03e821" }

  before do
    Project.create_with_id(project_id, name: "Test-Project") unless Project[project_id]
    Project.create_with_id(minio_service_project_id, name: "Minio-Service-Project") unless Project[minio_service_project_id]
    allow(Config).to receive(:minio_service_project_id).and_return(minio_service_project_id)
  end

  describe ".assemble" do
    let(:new_project_id) { "11111111-1111-1111-1111-111111111111" }
    let(:new_minio_service_id) { "22222222-2222-2222-2222-222222222222" }

    it "creates a strand and projects if they don't exist" do
      allow(Config).to receive(:minio_service_project_id).and_return(new_minio_service_id)
      st = described_class.assemble(new_project_id)
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
      expect(Project[new_project_id]).not_to be_nil
      expect(Project[new_minio_service_id]).not_to be_nil
    end

    it "reuses existing projects" do
      st = described_class.assemble(project_id)
      expect(st).to be_a Strand
      expect(Project[project_id].name).to eq("Test-Project")
      expect(Project[minio_service_project_id].name).to eq("Minio-Service-Project")
    end
  end

  describe "#start" do
    it "creates a minio cluster and hops to wait" do
      expect { minio_test.start }.to hop("wait")
      minio_cluster_id = frame_value(minio_test, "minio_cluster_id")
      expect(minio_cluster_id).not_to be_nil
      expect(MinioCluster[minio_cluster_id]).not_to be_nil
    end
  end

  describe "#wait" do
    before do
      minio_cluster_strand = Prog::Minio::MinioClusterNexus.assemble(project_id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
      refresh_frame(minio_test, new_values: {"minio_cluster_id" => minio_cluster_strand.id})
      @minio_cluster_strand = minio_cluster_strand
    end

    it "naps for 10 seconds if the minio cluster is not ready" do
      expect { minio_test.wait }.to nap(10)
    end

    it "naps for 30 seconds if the minio cluster is ready" do
      @minio_cluster_strand.update(label: "wait")
      expect { minio_test.wait }.to nap(30)
    end

    it "hops to wait_destroy if the minio cluster is being destroyed" do
      @minio_cluster_strand.update(label: "destroy")
      expect { minio_test.wait }.to hop("wait_destroy")
    end
  end

  describe "#wait_destroy" do
    it "naps if the minio cluster still exists" do
      minio_cluster_strand = Prog::Minio::MinioClusterNexus.assemble(project_id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
      refresh_frame(minio_test, new_values: {"minio_cluster_id" => minio_cluster_strand.id})
      expect { minio_test.wait_destroy }.to nap(5)
    end

    it "pops if the minio cluster is destroyed" do
      refresh_frame(minio_test, new_values: {"minio_cluster_id" => nil})
      expect { minio_test.wait_destroy }.to exit({"msg" => "MinIO cluster destroyed"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { minio_test.failed }.to nap(15)
    end
  end

  describe "#before_run" do
    before do
      minio_cluster_strand = Prog::Minio::MinioClusterNexus.assemble(project_id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
      refresh_frame(minio_test, new_values: {"minio_cluster_id" => minio_cluster_strand.id})
      @minio_cluster_strand = minio_cluster_strand
    end

    it "triggers destruction when destroy semaphore is set" do
      minio_test.strand.update(label: "wait")
      expect(minio_test).to receive(:destroy_set?).and_return(true)
      expect { minio_test.before_run }.to hop("wait_destroy")
      expect(@minio_cluster_strand.subject.destroy_set?).to be true
    end

    it "does not trigger destruction from wait_destroy label" do
      minio_test.strand.update(label: "wait_destroy")
      # before_run short-circuits when label is wait_destroy, so destroy_set? is never called
      expect(minio_test).not_to receive(:destroy_set?)
      expect { minio_test.before_run }.not_to hop("wait_destroy")
    end
  end

  describe "#minio_cluster" do
    it "returns the minio cluster" do
      minio_cluster_strand = Prog::Minio::MinioClusterNexus.assemble(project_id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
      refresh_frame(minio_test, new_values: {"minio_cluster_id" => minio_cluster_strand.id})
      expect(minio_test.minio_cluster).to be_a(MinioCluster)
      expect(minio_test.minio_cluster.id).to eq(minio_cluster_strand.id)
    end

    it "returns nil if minio_cluster_id is nil" do
      refresh_frame(minio_test, new_values: {"minio_cluster_id" => nil})
      expect(minio_test.minio_cluster).to be_nil
    end
  end
end
