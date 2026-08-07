# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SendNotification do
  subject(:sn) { described_class.new(st) }

  let(:resource_id) { "6181ddb3-0002-8ad0-9aeb-084832c9273b" }

  let(:st) {
    Strand.create(
      prog: "SendNotification", label: "start",
      stack: [{"event" => "postgres_failover", "resource_id" => resource_id, "params" => {"mode" => "unplanned", "server_ubid" => "ps-old-primary", "ts_completed" => "2026-08-05T18:00:00Z"}}],
    )
  }

  describe "#assemble" do
    it "creates a strand carrying the event and its details" do
      st = described_class.assemble(
        event: "postgres_failover", resource_id:,
        mode: "unplanned", server_ubid: "ps-old-primary", ts_completed: "2026-08-05T18:00:00Z",
      ).reload

      expect(st.label).to eq("start")
      expect(st.stack[0]).to eq(
        "event" => "postgres_failover", "resource_id" => resource_id,
        "params" => {"mode" => "unplanned", "server_ubid" => "ps-old-primary", "ts_completed" => "2026-08-05T18:00:00Z"},
      )
    end
  end

  describe "#start" do
    it "delivers a postgres failover event by emailing from the resource" do
      resource = instance_double(PostgresResource)
      expect(PostgresResource).to receive(:[]).with(resource_id).and_return(resource)
      expect(resource).to receive(:send_failover_email).with(
        mode: "unplanned", server_ubid: "ps-old-primary", ts_completed: "2026-08-05T18:00:00Z",
      )
      expect { sn.start }.to exit({"msg" => "sent"})
    end

    it "pops without delivering when the resource was destroyed in the meantime" do
      expect(PostgresResource).to receive(:[]).with(resource_id).and_return(nil)
      expect { sn.start }.to exit({"msg" => "sent"})
    end

    it "fails on an event it does not know how to deliver" do
      st.update(stack: [{"event" => "solar_flare", "resource_id" => resource_id, "params" => {}}])
      expect { sn.start }.to raise_error(RuntimeError, "unknown notification event: solar_flare")
    end

    it "re-raises errors below the attempt limit so respirate retries with backoff" do
      expect(PostgresResource).to receive(:[]).and_raise(StandardError.new("database is busy"))
      expect { sn.start }.to raise_error(StandardError, "database is busy")
    end

    it "logs and pops once the attempt limit is exhausted" do
      st.update(try: described_class::MAX_ATTEMPTS)
      expect(PostgresResource).to receive(:[]).and_raise(StandardError.new("database is busy"))
      expect(Clog).to receive(:emit).with("notification failed", anything).and_call_original
      expect { sn.start }.to exit({"msg" => "gave up after #{described_class::MAX_ATTEMPTS} attempts"})
    end
  end
end
