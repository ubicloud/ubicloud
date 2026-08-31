# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::TeardownLogAggregation do
  subject(:nx) { described_class.new(st) }

  let(:postgres_project) { Project.create(name: "postgres-service-project") }
  let(:ubid) { "pgvpn8xa4y1jkk8gzgrp5t4h5v" }
  let(:st) { described_class.assemble(ubid) }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  describe ".assemble" do
    it "creates a strand with no parent, carrying the ubid in its frame" do
      expect(st.prog).to eq("Postgres::TeardownLogAggregation")
      expect(st.label).to eq("start")
      expect(st.parent_id).to be_nil
      expect(st.stack[0]["ubid"]).to eq(ubid)
    end
  end

  describe "#start" do
    it "registers a deadline that pages as a warning, then hops" do
      expect { nx.start }.to hop("teardown")
      expect(nx.strand.stack[0]["deadline_target"]).to be_nil
      expect(nx.strand.stack[0]["deadline_page"]).to eq("warning")
      expect(Time.parse(nx.strand.stack[0]["deadline_at"])).to be_within(60).of(Time.now + 60 * 60)
    end
  end

  describe "#teardown" do
    it "deletes the stream, user and role" do
      client = instance_double(Parseable::Client)
      expect(ParseableResource).to receive(:client_for_project).and_return(client)
      expect(client).to receive(:delete_stream).with(stream_name: ubid)
      expect(client).to receive(:delete_user).with(user_id: ubid)
      expect(client).to receive(:delete_role).with(role_name: ubid)

      expect { nx.teardown }.to exit({"msg" => "log aggregation teardown is complete"})
    end

    it "pops if parseable is not configured in this environment" do
      expect { nx.teardown }.to exit({"msg" => "log aggregation teardown is complete"})
    end

    it "does not swallow errors from parseable, so the strand retries" do
      client = instance_double(Parseable::Client)
      expect(ParseableResource).to receive(:client_for_project).and_return(client)
      expect(client).to receive(:delete_stream).and_raise(Parseable::Client::Error.new("boom"))

      expect { nx.teardown }.to raise_error(Parseable::Client::Error, "boom")
    end
  end
end
