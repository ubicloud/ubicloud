# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresBackupMeteringState do
  let(:timeline) { create_postgres_timeline(location_id: Location::HETZNER_FSN1_ID) }

  it "is destroyed together with its timeline" do
    ledger = described_class.create(swept_at: Time.now) { it.id = timeline.id }
    timeline.destroy

    expect(ledger).not_to exist
  end

  describe ".sweep_due?" do
    it "is true for a timeline with no row at all" do
      expect(described_class.sweep_due?(timeline.id)).to be true
    end
  end

  describe ".record" do
    it "inserts a row and then updates it in place, leaving other columns alone" do
      described_class.record(timeline.id, {wal_bytes: 1, cursor: "wal_005/a"})
      described_class.record(timeline.id, {wal_bytes: 2})

      row = described_class[timeline.id]
      expect(row.wal_bytes).to eq(2)
      expect(row.cursor).to eq("wal_005/a")
      expect(described_class.count).to eq(1)
    end
  end
end
