# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresBackupMeteringState do
  let(:timeline) { create_postgres_timeline(location_id: Location::HETZNER_FSN1_ID) }

  it "is destroyed together with its timeline" do
    ledger = described_class.create(swept_at: Time.now) { it.id = timeline.id }
    timeline.destroy

    expect(ledger).not_to exist
  end
end
