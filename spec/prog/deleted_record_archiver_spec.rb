# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DeletedRecordArchiver do
  subject(:prog) {
    described_class.new(Strand.create_with_id(UBID.parse("stde1etedrecyarch1verzzzzy").to_uuid, prog: "DeletedRecordArchiver", label: "wait"))
  }

  let(:day) { Time.now.utc.to_date - 2 }
  let(:day_start) { Time.utc(day.year, day.month, day.day) }
  let(:day_end) { day_start + (24 * 60 * 60) }
  let(:uploads) { [] }

  let(:s3) {
    client = Aws::S3::Client.new(stub_responses: true)
    client.stub_responses(:put_object, lambda { |context|
      body = context.params[:body]
      body.rewind
      uploads << {key: context.params[:key], body: body.read, content_length: context.params[:content_length]}
      body.rewind
      {etag: "\"stub-etag\""}
    })
    client
  }

  let(:archive) { DB[:deleted_record_archive] }
  let(:slices) { DB[:deleted_record_archive_slice].order(:period) }

  before do
    allow(Config).to receive_messages(
      deleted_record_archive_bucket: "archive",
      deleted_record_archive_endpoint: "https://minio.example.com",
      deleted_record_archive_access_key: "key",
      deleted_record_archive_secret_key: "secret",
    )
    allow(prog).to receive(:blob_storage_client).and_return(s3)
  end

  def add_rows(count, at)
    DB[:deleted_record].import(
      [:deleted_at, :model_name, :record_id, :model_values],
      Array.new(count) { [at, "Vm", Vm.generate_uuid, Sequel.pg_jsonb({"name" => "vm-1", "note" => "a,b\"c"})] },
    )
  end

  def period(from, to)
    Sequel.pg_range(from...to, :tstzrange)
  end

  def uncompressed(upload)
    Zlib::GzipReader.new(StringIO.new(upload[:body])).read
  end

  describe "#wait" do
    it "naps without touching anything when no bucket is configured" do
      expect(Config).to receive(:deleted_record_archive_bucket).at_least(:once).and_return(nil)
      expect(prog).not_to receive(:next_action)
      expect { prog.wait }.to nap(60 * 60)
    end

    it "naps with no deadline armed when there is nothing to archive" do
      expect { prog.wait }.to nap(5 * 60)
      expect(prog.strand.stack.first).not_to include("deadline_at")
    end

    it "arms the stall deadline before hopping to work" do
      DeletedRecord.create_partition(day)
      expect { prog.wait }.to hop("archive")
      expect(prog.strand.stack.first["deadline_target"]).to eq "wait"
      expect(Time.new(prog.strand.stack.first["deadline_at"])).to be_within(60).of(Time.now + described_class::STALL_DEADLINE)
    end
  end

  describe "#archive" do
    it "hops back to wait when there is nothing to do" do
      expect { prog.archive }.to hop("wait")
    end

    it "opens a sealed day, with nothing archived of it yet" do
      DeletedRecord.create_partition(day)
      add_rows(2, day_start + 3600)

      expect { prog.archive }.to nap(1)

      expect(archive.first(day:)[:verified_at]).to be_nil
      expect(slices.count).to eq 0
      expect(prog.archived_through(day)).to eq day_start
    end

    it "leaves the stall deadline where wait armed it, so no day outlasts it" do
      DeletedRecord.create_partition(day)
      add_rows(2, day_start + 3600)
      expect { prog.wait }.to hop("archive")
      armed = prog.strand.stack.first["deadline_at"]

      expect { prog.archive }.to nap(1)
      expect { prog.archive }.to nap(1)

      expect(prog.strand.stack.first["deadline_at"]).to eq armed
    end

    it "opens a partition created out of order, rather than skipping it" do
      DeletedRecord.create_partition(day)
      archive.insert(day:, verified_at: Time.now)

      older = day - 5
      DeletedRecord.create_partition(older)
      expect { prog.archive }.to nap(1)
      expect(archive.order(:day).select_map(:day)).to eq [older, day]
    end

    it "finishes the day in flight before opening the next one" do
      DeletedRecord.create_partition(day)
      prog.open_day(day)
      DeletedRecord.create_partition(day - 5)

      expect { prog.archive }.to nap(1)
      expect(archive.select_map(:day)).to eq [day]
      expect(slices.count).to eq 1
    end

    it "summarizes the day's brin index, not one of its btrees, as it opens it" do
      DeletedRecord.create_partition(day)
      add_rows(20, day_start + 3600)

      summarized = nil
      expect(DB).to receive(:get) do |arg|
        summarized = arg.args.first.expr
        0
      end

      expect { prog.archive }.to nap(1)
      expect(summarized).to eq "#{DeletedRecord.partition_name(day)}_deleted_at_idx"
    end

    it "does not open a day that can still change" do
      expect { prog.archive }.to hop("wait")
      expect(archive.count).to eq 0
    end
  end

  describe "slice upload" do
    before do
      DeletedRecord.create_partition(day)
      add_rows(3, day_start + 1800)
      add_rows(1, day_start + (23 * 3600) + 1800)
      prog.open_day(day)
    end

    it "counts a row whose text carries a newline as one row" do
      DB[:deleted_record].insert(deleted_at: day_start + 60, model_name: "Two\nLines", model_values: Sequel.pg_jsonb({}))

      expect { prog.archive }.to nap(1)

      expect(uncompressed(uploads[0]).count("\n")).to eq 5
      expect(slices.first[:row_count]).to eq 4
    end

    it "copies an hour into one gzipped object and commits its manifest row" do
      expect { prog.archive }.to nap(1)

      expect(uploads.length).to eq 1
      expect(uploads[0][:key]).to eq "date=#{day}/0000-0100.csv.gz"

      csv = uncompressed(uploads[0])
      expect(csv.count("\n")).to eq 3
      expect(csv).to include("Vm")
      expect(csv.lines.first).to start_with "#{day} 00:30:00+00,Vm,"
      expect(csv.scan('"{""name"": ""vm-1"", ""note"": ""a,b\""c""}"').length).to eq 3

      slice = slices.first
      expect(slice[:row_count]).to eq 3
      expect(slice[:bytes]).to eq uploads[0][:content_length]
      expect(slice[:etag]).to eq "\"stub-etag\""
      expect(prog.archived_through(day)).to eq slice[:period].end
      expect(slice[:period]).to eq(day_start...day_start + 3600)

      expect { prog.archive }.to nap(1)
      expect(uploads.map { it[:key] }).to eq [
        "date=#{day}/0000-0100.csv.gz",
        "date=#{day}/0100-0200.csv.gz",
      ]
      expect(slices.select_map(:row_count)).to eq [3, 0]
      expect(uncompressed(uploads[1])).to eq ""
    end

    it "labels the window that ends the day 2400" do
      slices.insert(day:, period: period(day_start, day_end - 3600),
        object_key: "date=#{day}/0000-2300.csv.gz", row_count: 0, bytes: 0)
      expect { prog.archive }.to nap(1)
      expect(uploads[0][:key]).to eq "date=#{day}/2300-2400.csv.gz"
      expect(prog.archived_through(day)).to eq day_end
    end

    it "reruns a slice after a crash before the commit, overwriting the same key with the same bytes" do
      expect { prog.archive }.to nap(1)
      first = uploads[0]

      slices.where(period: period(day_start, day_start + 3600)).delete

      expect { prog.archive }.to nap(1)
      expect(uploads[1][:key]).to eq first[:key]
      expect(uncompressed(uploads[1])).to eq uncompressed(first)
    end

    it "ships the same rows however they are batched into the write buffer" do
      expect { prog.archive }.to nap(1)
      buffered = uploads[0]

      slices.where(period: period(day_start, day_start + 3600)).delete
      stub_const("Prog::DeletedRecordArchiver::WRITE_BUFFER_BYTES", 1)

      expect { prog.archive }.to nap(1)
      expect(uncompressed(uploads[1])).to eq uncompressed(buffered)
      expect(slices.first[:row_count]).to eq 3
    end

    it "leaves no trace when the copy fails partway through" do
      expect(DB).to receive(:copy_table).and_raise(Zlib::BufError)

      expect { prog.archive }.to raise_error(Zlib::BufError)
      expect(uploads).to be_empty
      expect(slices.count).to eq 0
      expect(prog.archived_through(day)).to eq day_start
    end

    it "cannot record the same window twice" do
      expect { prog.archive }.to nap(1)

      expect {
        slices.insert(day:, period: period(day_start, day_start + 3600),
          object_key: "date=#{day}/other.csv.gz", row_count: 3, bytes: 1)
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "cannot record a window overlapping one already archived" do
      expect { prog.archive }.to nap(1)

      expect {
        slices.insert(day:, period: period(day_start + 1800, day_start + 5400),
          object_key: "date=#{day}/0030-0130.csv.gz", row_count: 0, bytes: 0)
      }.to raise_error(Sequel::Postgres::ExclusionConstraintViolation)
    end

    it "cannot record a window reaching outside its day" do
      expect {
        slices.insert(day:, period: period(day_end, day_end + 3600),
          object_key: "date=#{day}/2400-2500.csv.gz", row_count: 0, bytes: 0)
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it "snaps a manifest that ends off the hour grid back onto it" do
      slices.insert(day:, period: period(day_start, day_start + 60),
        object_key: "date=#{day}/0000-0001.csv.gz", row_count: 0, bytes: 0)

      expect { prog.archive }.to nap(1)

      expect(uploads.map { it[:key] }).to eq ["date=#{day}/0001-0100.csv.gz"]
      expect(prog.archived_through(day)).to eq day_start + 3600
    end
  end

  describe "verification" do
    before do
      DeletedRecord.create_partition(day)
      add_rows(2, day_start + 1800)
      prog.open_day(day)
      24.times { expect { prog.archive }.to nap(1) }
      expect(prog.archived_through(day)).to eq day_end
    end

    it "verifies a day whose objects account for every row in its partition" do
      expect { prog.archive }.to hop("wait").and change { archive.first(day:)[:verified_at] }.from(nil)
    end

    it "pages instead of verifying when the archive and the partition disagree" do
      add_rows(1, day_start + 7200)

      expect { prog.archive }.to nap(15 * 60)
      expect(archive.first(day:)[:verified_at]).to be_nil

      page = Page.first
      expect(page.summary).to eq "deleted_record archive for #{day} does not match its partition"
      expect(page.details["archived_rows"]).to eq 2
      expect(page.details["partition_rows"]).to eq 3
    end

    it "resolves the page once the counts agree again" do
      add_rows(1, day_start + 7200)
      expect { prog.archive }.to nap(15 * 60)
      page = Page.first

      DB[:deleted_record].where(deleted_at: day_start + 7200).delete
      expect { prog.archive }.to hop("wait").and change { archive.first(day:)[:verified_at] }.from(nil)
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq 1
    end
  end

  describe "#drop_unarchived" do
    let(:expired) { Time.now.utc.to_date - DeletedRecord::RETENTION_DAYS - 1 }

    context "when running in development" do
      before do
        allow(Config).to receive(:development?).and_return(true)
      end

      it "drops partitions past retention, where nothing archives them" do
        expect(Config).to receive(:deleted_record_archive_bucket).at_least(:once).and_return(nil)
        DeletedRecord.create_partition(expired - 1)
        DeletedRecord.create_partition(expired)

        expect { prog.wait }.to hop("drop_unarchived")

        # One per run, so the parent lock is never held across two, oldest first.
        expect { prog.drop_unarchived }.to hop("wait")
        expect(DeletedRecord.partition_days).not_to include(expired - 1)
        expect(DeletedRecord.partition_days).to include(expired)

        expect { prog.drop_unarchived }.to hop("wait")
        expect(DeletedRecord.partition_days).not_to include(expired)

        # Nothing expired left, so it stops hopping and waits without a bucket.
        expect { prog.drop_unarchived }.to hop("wait")
        expect { prog.wait }.to nap(60 * 60)
      end

      it "archives an old day rather than dropping it once a bucket is configured" do
        DeletedRecord.create_partition(expired)

        expect { prog.wait }.to hop("archive")
        expect(DeletedRecord.partition_days).to include(expired)
      end
    end

    it "leaves an old day alone outside development, however old" do
      expect(Config).to receive(:deleted_record_archive_bucket).at_least(:once).and_return(nil)
      DeletedRecord.create_partition(expired)

      expect { prog.wait }.to nap(60 * 60)
      expect(DeletedRecord.partition_days).to include(expired)
    end
  end

  describe "#drop_oldest_partition" do
    before do
      DeletedRecord.create_partition(day)
      archive.insert(day:, verified_at: Time.now)
    end

    it "hops back to wait when nothing is droppable yet" do
      expect { prog.drop_oldest_partition }.to hop("wait")
      expect(DeletedRecord.partition_days).to include(day)
      expect(archive.first(day:)[:dropped_at]).to be_nil
    end

    it "drops a verified partition once it is past the retention floor" do
      old = Time.now.utc.to_date - DeletedRecord::RETENTION_DAYS - 1
      DeletedRecord.create_partition(old)
      archive.insert(day: old, verified_at: Time.now)

      expect { prog.archive }.to hop("drop_oldest_partition")
      expect { prog.drop_oldest_partition }.to hop("wait").and change { archive.first(day: old)[:dropped_at] }.from(nil)
      expect(DeletedRecord.partition_days).not_to include(old)
    end

    it "records a day whose partition is already gone" do
      old = Time.now.utc.to_date - DeletedRecord::RETENTION_DAYS - 1
      archive.insert(day: old, verified_at: Time.now)

      expect { prog.drop_oldest_partition }.to hop("wait").and change { archive.first(day: old)[:dropped_at] }.from(nil)
    end

    it "never drops a day that was not verified" do
      old = Time.now.utc.to_date - DeletedRecord::RETENTION_DAYS - 1
      DeletedRecord.create_partition(old)
      archive.insert(day: old)

      expect(prog.droppable_day).to be_nil
      expect { prog.drop_oldest_partition }.to hop("wait")
      expect(DeletedRecord.partition_days).to include(old)
    end
  end

  describe "manifest pruning" do
    let(:ancient) { Time.now.utc.to_date - described_class::MANIFEST_RETENTION_DAYS - 1 }
    let(:ancient_start) { Time.utc(ancient.year, ancient.month, ancient.day) }

    it "prunes a day long dropped, taking its slices with it" do
      archive.insert(day: ancient, verified_at: Time.now, dropped_at: Time.now)
      slices.insert(day: ancient, period: period(ancient_start, ancient_start + 3600),
        object_key: "date=#{ancient}/0000-0100.csv.gz", row_count: 3, bytes: 1)

      expect { prog.archive }.to nap(1).and change { archive.where(day: ancient).count }.from(1).to(0)
      expect(slices.where(day: ancient).count).to eq 0
    end

    it "keeps a day still inside the manifest retention" do
      recent = Time.now.utc.to_date - described_class::MANIFEST_RETENTION_DAYS + 1
      archive.insert(day: recent, verified_at: Time.now, dropped_at: Time.now)

      expect { prog.archive }.to hop("wait")
      expect(archive.where(day: recent).count).to eq 1
    end

    it "never prunes a day whose partition may still be there, however old" do
      archive.insert(day: ancient, verified_at: Time.now)

      expect(prog.prunable_day).to be_nil
    end
  end

  describe "#blob_storage_client" do
    let(:unstubbed) { described_class.new(prog.strand) }

    it "talks to MinIO with path style addressing, trusting the default store" do
      client = unstubbed.blob_storage_client
      expect(client.config.endpoint.to_s).to eq "https://minio.example.com"
      expect(client.config.region).to eq "us-east-1"
      expect(client.config.force_path_style).to be true
      expect(client.config.ssl_ca_store).to be_nil
    end

    it "builds the client once" do
      client = unstubbed.blob_storage_client
      expect(unstubbed.blob_storage_client).to be client
    end
  end
end
