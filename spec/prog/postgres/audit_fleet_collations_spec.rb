# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::AuditFleetCollations do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:st) { described_class.assemble(concurrency: 2) }

  def create_child(resource_id, msg:, lease: Time.now - 10)
    Strand.create(
      parent_id: st.id,
      prog: "Postgres::AuditResourceCollation",
      label: "audit",
      stack: [{"subject_id" => resource_id}],
      exitval: Sequel.pg_jsonb_wrap({"msg" => msg}),
      lease:,
    )
  end

  def reload_frame
    st.reload.stack.first
  end

  describe ".assemble" do
    it "enqueues every primary and skips read replicas" do
      r1 = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource: r1)
      r2 = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource: r2)
      replica = create_postgres_resource(project:, location_id:)
      replica.update(parent_id: r1.id)
      create_postgres_server(resource: replica)

      strand = described_class.assemble
      expect(strand.prog).to eq("Postgres::AuditFleetCollations")
      expect(strand.label).to eq("wait")
      expect(strand.stack.first["todo"]).to contain_exactly(r1.id, r2.id)
      expect(strand.stack.first["concurrency"]).to eq(10)
      expect(strand.stack.first["flagged"]).to eq([])
    end
  end

  describe "#wait" do
    it "buds children up to the concurrency limit and moves them in progress" do
      st.stack.first["todo"] = %w[a b c]
      st.modified!(:stack)
      st.save_changes

      expect { nx.wait }.to nap(10)

      expect(nx.strand.children.map(&:prog).uniq).to eq(["Postgres::AuditResourceCollation"])
      expect(nx.strand.children.count).to eq(2)
      expect(reload_frame["in_progress"].count).to eq(2)
      expect(reload_frame["todo"]).to eq(["c"])
    end

    it "reaps exited children into their verdict buckets and refills slots" do
      st.stack.first["todo"] = ["c"]
      st.stack.first["in_progress"] = %w[flag clean]
      st.modified!(:stack)
      st.save_changes
      create_child("flag", msg: "flagged")
      create_child("clean", msg: "clean")

      expect { nx.wait }.to nap(10)

      frame = reload_frame
      expect(frame["flagged"]).to eq(["flag"])
      expect(frame["clean"]).to eq(["clean"])
      # the two exited children are reaped and a fresh child is budded for "c"
      expect(frame["in_progress"]).to eq(["c"])
      expect(frame["todo"]).to eq([])
      expect(nx.strand.children.map { it.stack.first["subject_id"] }).to eq(["c"])
    end

    it "classifies skipped, unreachable, and gone children" do
      st.stack.first["todo"] = []
      st.stack.first["in_progress"] = %w[s u g]
      st.modified!(:stack)
      st.save_changes
      create_child("s", msg: "skipped")
      create_child("u", msg: "unreachable")
      create_child("g", msg: "postgres resource is gone")

      expect { nx.wait }.to exit({"msg" => "fleet collation audit completed", "flagged" => [], "unreachable" => ["u"], "clean" => 0, "skipped" => 2})
    end

    it "pops a summary when nothing is left to do" do
      expect { nx.wait }.to exit({"msg" => "fleet collation audit completed", "flagged" => [], "unreachable" => [], "clean" => 0, "skipped" => 0})
    end
  end
end
