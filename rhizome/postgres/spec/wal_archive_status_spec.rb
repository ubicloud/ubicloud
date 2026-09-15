# frozen_string_literal: true

require "logger"
require_relative "../lib/wal_archive_status"

RSpec.describe WalArchiveStatus do
  let(:logger) { instance_double(Logger, info: nil) }
  let(:status) { described_class.new(18, logger) }
  let(:path) { "/dat/18/data/pg_wal/archive_status" }

  describe "#wal_end_segment" do
    it "returns the log and segment ids of the segment holding the end of the received WAL" do
      expect(status).to receive(:_run_command).with("sudo -u postgres psql -t -A -c 'SELECT greatest(pg_catalog.pg_last_wal_receive_lsn(), pg_catalog.pg_last_wal_replay_lsn())'").and_return("2AE/97A3F1D0\n")
      expect(status.wal_end_segment).to eq("000002AE00000097")
    end
  end

  describe "#complete_segments" do
    it "returns every segment with a done marker below the end of WAL, oldest first" do
      expect(status).to receive(:wal_end_segment).and_return("000002AE00000097")
      expect(Dir).to receive(:children).with(path).and_return([
        "00000002.history.done",
        "00000001000002AE00000097.done",
        "00000001000002AE00000098.ready",
        "00000001000002AE00000096.done",
        "00000001000002AE00000093.done",
        "00000001000002AE00000095.done",
        "00000001000002AE00000094.done",
      ])
      expect(status.complete_segments).to eq(["00000001000002AE00000093", "00000001000002AE00000094", "00000001000002AE00000095", "00000001000002AE00000096"])
    end
  end

  describe "#mark_received_segments_ready" do
    it "renames the done markers to ready and skips segments recycled meanwhile" do
      expect(status).to receive(:complete_segments).and_return(["00000001000002AE00000096", "00000001000002AE00000095"])
      expect(File).to receive(:rename).with("#{path}/00000001000002AE00000096.done", "#{path}/00000001000002AE00000096.ready")
      expect(File).to receive(:rename).with("#{path}/00000001000002AE00000095.done", "#{path}/00000001000002AE00000095.ready").and_raise(Errno::ENOENT)
      expect(logger).to receive(:info).with("1 received segments marked ready for archiving")
      status.mark_received_segments_ready
    end
  end
end
