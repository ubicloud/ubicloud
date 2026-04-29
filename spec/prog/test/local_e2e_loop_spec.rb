# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::LocalE2eLoop do
  subject(:lel) { described_class.new(lel_strand) }

  let(:lel_strand) { described_class.assemble(progs: ["PostgresResource", "HaPostgresResource"], provider: "metal") }

  describe ".assemble" do
    it "creates a strand" do
      expect(lel_strand.prog).to eq "Test::LocalE2eLoop"
      expect(lel_strand.label).to eq "start"
      expect(lel_strand.stack).to eq [{
        "progs" => %w[PostgresResource HaPostgresResource],
        "prog_args" => {"provider" => "metal"},
        "starts" => 0,
        "successes" => 0,
        "failures" => 0,
        "nap" => false,
        "nap_between" => 60,
        "current_strand" => nil,
      }]
    end

    it "fails if one of the progs is invalid" do
      expect do
        described_class.assemble(progs: ["PostgresResource", "LocalE2eLoop"], provider: "metal")
      end.to raise_error(RuntimeError, "invalid local E2E prog")
    end
  end

  describe "#before_run" do
    it "naps if pause is set" do
      Semaphore.incr(lel_strand.id, "pause")
      expect { lel.before_run }.to nap(60 * 60)
    end

    it "does nothing if pause is not set" do
      expect(lel.before_run).to be_nil
    end
  end

  describe "#start" do
    it "starts a child strand" do
      service_project = Project.create(name: "Postgres-Service-Project")
      expect(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
      expect { lel.start }.to hop("wait")
        .and change { lel_strand.children_dataset.count }.from(0).to(1)
      child = lel_strand.children.first
      expect(
        lel_strand.stack[0].values_at("current_strand", "starts", "progs"),
      ).to eq [child.id, 1, %w[HaPostgresResource PostgresResource]]
      expect(child.prog).to eq "Test::PostgresResource"
      expect(child.stack[0]["provider"]).to eq "metal"
      expect(child.stack[0]["local_e2e"]).to be true
    end
  end

  describe "#wait" do
    it "hops to nap_between if there are no child strands" do
      expect { lel.wait }.to hop("nap_between")
      expect(
        lel_strand.stack[0].values_at("current_strand", "successes", "failures", "nap"),
      ).to eq [nil, 0, 0, false]
    end

    it "handles failed child strand" do
      Strand.create(parent_id: lel_strand.id, prog: "Test::PostgresResource", label: "start", exitval: {})
      expect { lel.wait }.to hop("nap_between")
      expect(
        lel_strand.stack[0].values_at("current_strand", "successes", "failures", "nap"),
      ).to eq [nil, 0, 1, true]
    end

    it "handles successful child strand" do
      Strand.create(parent_id: lel_strand.id, prog: "Test::PostgresResource", label: "start", exitval: {"msg" => "Postgres tests are finished!"})
      expect { lel.wait }.to hop("nap_between")
      expect(
        lel_strand.stack[0].values_at("current_strand", "successes", "failures", "nap"),
      ).to eq [nil, 1, 0, true]
    end
  end

  describe "#nap_between" do
    it "naps if nap is set" do
      refresh_frame(lel, new_values: {"nap" => true})
      expect { lel.nap_between }.to nap(60)
    end

    it "hops to start if nap is not set" do
      expect { lel.nap_between }.to hop("start")
    end
  end

  describe "#destroy" do
    it "exits" do
      expect { lel.destroy }.to exit({"msg" => "destruction of local E2E loop prog requested"})
    end
  end
end
