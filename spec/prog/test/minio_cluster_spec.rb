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
    let(:new_minio_service_id) { "22222222-2222-2222-2222-222222222222" }

    it "creates a strand and minio service project if it doesn't exist" do
      allow(Config).to receive(:minio_service_project_id).and_return(new_minio_service_id)
      st = described_class.assemble(project_id)
      expect(st).to be_a Strand
      expect(st.label).to eq("start")
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

    it "naps for 10 seconds" do
      expect { minio_test.wait }.to nap(10)
    end

    it "hops to trigger_destroy when destroy_and_verify semaphore is set" do
      expect(minio_test).to receive(:destroy_and_verify_set?).and_return(true)
      expect { minio_test.wait }.to hop("trigger_destroy")
    end
  end

  describe "#trigger_destroy" do
    before do
      minio_cluster_strand = Prog::Minio::MinioClusterNexus.assemble(project_id, "test-minio", Location::HETZNER_FSN1_ID, "admin", 32, 1, 1, 1, "standard-2")
      refresh_frame(minio_test, new_values: {"minio_cluster_id" => minio_cluster_strand.id})
      @minio_cluster_strand = minio_cluster_strand
    end

    it "increments destroy on minio cluster and hops to wait_destroy" do
      expect { minio_test.trigger_destroy }.to hop("wait_destroy")
      expect(@minio_cluster_strand.subject.destroy_set?).to be true
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
