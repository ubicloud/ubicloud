# frozen_string_literal: true

require "logger"
require_relative "../lib/wal_archive_backfill"

RSpec.describe WalArchiveBackfill do
  let(:logger) { instance_double(Logger, info: nil) }
  let(:backfill) { described_class.new(17, logger, max_segments: 3) }
  let(:pg_wal) { "/dat/17/data/pg_wal" }

  describe "#current_timeline" do
    it "reads the newest history file" do
      expect(Dir).to receive(:glob).with("#{pg_wal}/*.history").and_return(["#{pg_wal}/00000007.history", "#{pg_wal}/00000010.history", "#{pg_wal}/00000008.history"])
      expect(backfill.current_timeline).to eq(16)
    end

    it "fails when there is no history file" do
      expect(Dir).to receive(:glob).with("#{pg_wal}/*.history").and_return([])
      expect { backfill.current_timeline }.to raise_error(RuntimeError, "no timeline history file in /dat/17/data/pg_wal")
    end
  end

  describe "#candidates" do
    it "returns complete segments from older timelines, newest first, up to the cap" do
      expect(backfill).to receive(:current_timeline).and_return(8)
      expect(Dir).to receive(:children).with(pg_wal).and_return([
        "00000008.history",
        "00000007000002F2000000B5.partial",
        "00000008000002F2000000B5",
        "00000008000002F2000000B6",
        "00000007000002F2000000B1",
        "00000007000002F2000000B4",
        "00000007000002F2000000B2",
        "00000006000002F2000000A9",
        "00000007000002F2000000B3",
        "archive_status",
      ])
      expect(backfill.candidates).to eq(["00000007000002F2000000B4", "00000007000002F2000000B3", "00000007000002F2000000B2"])
    end
  end

  describe "#run" do
    it "pushes the candidates that still exist and reports which ones wal-g actually uploaded" do
      expect(backfill).to receive(:candidates).and_return(["00000007000002F2000000B4", "00000007000002F2000000B3", "00000007000002F2000000B2"])
      expect(File).to receive(:exist?).with("#{pg_wal}/00000007000002F2000000B4").and_return(true)
      expect(File).to receive(:exist?).with("#{pg_wal}/00000007000002F2000000B3").and_return(true)
      expect(File).to receive(:exist?).with("#{pg_wal}/00000007000002F2000000B2").and_return(false)
      expect(backfill).to receive(:_run_command).with(
        "sudo -u postgres env WALG_PREVENT_WAL_OVERWRITE=true WALG_UPLOAD_CONCURRENCY=1 wal-g wal-push #{pg_wal}/00000007000002F2000000B4 --config /etc/postgresql/wal-g.env 2>&1",
      ).and_return("INFO: 2026/08/24 21:43:56.354760 FILE PATH: 00000007000002F2000000B4.lz4\n")
      expect(backfill).to receive(:_run_command).with(
        "sudo -u postgres env WALG_PREVENT_WAL_OVERWRITE=true WALG_UPLOAD_CONCURRENCY=1 wal-g wal-push #{pg_wal}/00000007000002F2000000B3 --config /etc/postgresql/wal-g.env 2>&1",
      ).and_return("INFO: 2026/08/24 21:43:57.100000 WAL file '#{pg_wal}/00000007000002F2000000B3' already archived with equal content, skipping\n")
      expect(logger).to receive(:info).with("3 old-timeline segments to check")
      expect(logger).to receive(:info).with("uploaded: 00000007000002F2000000B4")
      expect(logger).to receive(:info).with("already archived: 00000007000002F2000000B3")
      expect(logger).to receive(:info).with("recycled meanwhile: 00000007000002F2000000B2")
      expect(logger).to receive(:info).with("done: 1 uploaded, 1 already archived, 1 recycled meanwhile")
      backfill.run
    end
  end
end
