# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::BackupMetering do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "backup-metering-test") }
  let(:location) { create_postgres_aws_location }
  let(:timeline) { create_postgres_timeline(location_id: location.id) }
  let(:pg) { create_postgres_resource(project:, location_id: location.id) }
  let(:s3_client) { Aws::S3::Client.new(stub_responses: true) }

  let(:strand) {
    Strand.create(prog: "Postgres::BackupMetering", label: "start",
      parent_id: pg.strand.id, stack: [{"subject_id" => pg.id}])
  }

  before do
    allow(Config).to receive(:postgres_backup_metering_enabled).and_return(true)
    allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
    allow(Clog).to receive(:emit).and_call_original
    create_postgres_server(resource: pg, timeline:)
  end

  def object(key, minutes_ago, size)
    {key:, last_modified: Time.now - (minutes_ago * 60), size:}
  end

  # wal-g names segments <timeline 8hex><log 8hex><seg 8hex>, and only those
  # count as the oldest survivor, so the boundary probe needs real ones.
  def wal_key(n)
    format("wal_005/%024X.lz4", n)
  end

  # Answers per prefix rather than per call, so an example does not have to
  # know how many requests the sweep makes or in what order.
  def stub_listing(wal: [], backups: [])
    s3_client.stub_responses(:list_objects_v2, lambda { |context|
      params = context.params
      next {contents: backups, is_truncated: false} unless params[:prefix] == "wal_005/"

      after = params[:start_after]
      {contents: after ? wal.select { it[:key] > after } : wal, is_truncated: false}
    })
  end

  # Serves the sentinel listing separately from the object walk, so an example
  # can page the walk or fail one listing without touching the other.
  def stub_backup_listing(sentinels:, pages: 1, size: 100, &each_page)
    served = 0
    s3_client.stub_responses(:list_objects_v2, lambda { |context|
      next {contents: [], is_truncated: false} if context.params[:prefix] == "wal_005/"
      next {contents: sentinels, is_truncated: false} if context.params[:delimiter] == "/"

      each_page&.call(served)
      served += 1
      truncated = served < pages
      {contents: [object("basebackups_005/base_001/tar_partitions/part_#{served}.tar.lz4", 60, size)],
       is_truncated: truncated, next_continuation_token: truncated ? "next" : nil}
    })
  end

  # One object per page, so an example can drive the real page budget rather
  # than stub the constant: the prog class is frozen under CLOVER_FREEZE.
  def stub_paged_listing(prefix, total)
    served = 0
    s3_client.stub_responses(:list_objects_v2, lambda { |context|
      next {contents: [], is_truncated: false} unless context.params[:prefix] == prefix

      served += 1
      truncated = served < total
      {contents: [{key: format("#{prefix}%06d", served), last_modified: Time.now - 7200, size: 100}],
       is_truncated: truncated, next_continuation_token: truncated ? "next" : nil}
    })
  end

  def create_ledger(values)
    values = values.dup
    values[:wal_day_bytes] = Sequel.pg_jsonb(values[:wal_day_bytes]) if values[:wal_day_bytes]
    PostgresBackupMeteringState.create(values) { it.id = timeline.id }
  end

  def state
    PostgresBackupMeteringState[timeline.id]
  end

  def run_to_completion
    200.times do
      nx.strand.unsynchronized_run
      break if nx.strand.exitval
    end
    nx.strand.exitval
  end

  describe "#start" do
    context "when the feature is off" do
      before { allow(Config).to receive(:postgres_backup_metering_enabled).and_return(false) }

      it "pops without listing anything" do
        expect { nx.start }.to exit({"msg" => "backup metering disabled"})
      end
    end

    it "pops when the resource fetches from someone else's timeline" do
      pg.representative_server.update(timeline_access: "fetch")

      expect { nx.start }.to exit({"msg" => "not metered"})
    end

    it "pops when the resource has no representative server" do
      pg.representative_server.update(is_representative: false)

      expect { described_class.new(strand).start }.to exit({"msg" => "not metered"})
    end

    it "pops when the location is neither AWS nor GCP" do
      pg.update(location_id: Location::HETZNER_FSN1_ID)

      expect { nx.start }.to exit({"msg" => "not metered"})
    end

    it "hops to the WAL sweep with an empty ledger when there is no state" do
      expect { nx.start }.to hop("sweep_wal")
      expect(nx.frame["wal_cursor"]).to be_nil
      expect(nx.frame["wal_day_bytes"]).to eq({})
    end

    it "resumes from the stored cursor and ledger" do
      create_ledger({cursor: wal_key(1), wal_day_bytes: {"2026-09-01" => 10}})

      expect { nx.start }.to hop("sweep_wal")
      expect(nx.frame["wal_cursor"]).to eq(wal_key(1))
      expect(nx.frame["wal_day_bytes"]).to eq({"2026-09-01" => 10})
    end

    it "discards the cursor and ledger when a reconcile is requested" do
      create_ledger({cursor: wal_key(1), wal_day_bytes: {"2026-09-01" => 10}})
      pg.incr_reconcile_backup_metering

      expect { nx.start }.to hop("sweep_wal")
      expect(nx.frame["wal_cursor"]).to be_nil
      expect(nx.frame["wal_day_bytes"]).to eq({})
    end
  end

  describe "#sweep_wal" do
    it "buckets counted bytes by day and advances the cursor past them" do
      stub_listing(wal: [object(wal_key(1), 120, 100), object(wal_key(2), 60, 200)])
      day = (Time.now - 3600).utc.strftime("%Y-%m-%d")

      run_to_completion
      expect(state.wal_day_bytes.to_h).to eq({day => 300})
      expect(state.wal_bytes).to eq(300)
      expect(state.cursor).to eq(wal_key(2))
    end

    it "leaves the recent tail for the next sweep so a straggler is not skipped" do
      stub_listing(wal: [object(wal_key(1), 120, 100), object(wal_key(2), 1, 200), object(wal_key(3), 120, 400)])

      run_to_completion
      expect(state.wal_bytes).to eq(100)
      expect(state.cursor).to eq(wal_key(1))
    end

    it "lists only past the cursor on an incremental sweep" do
      create_ledger(
        {cursor: wal_key(1), wal_day_bytes: {"2026-09-01" => 10},
         boundary_probed_at: Time.now, boundary_day: Date.new(2026, 9, 1),
         backup_walked_at: Time.now, backup_bytes: 55},
      )
      stub_listing(wal: [object(wal_key(1), 120, 100), object(wal_key(2), 120, 200)])
      day = (Time.now - 7200).utc.strftime("%Y-%m-%d")

      run_to_completion
      expect(state.wal_day_bytes.to_h).to eq({"2026-09-01" => 10, day => 200})
      expect(state.cursor).to eq(wal_key(2))
    end

    it "resumes from the continuation token when a run hits its page budget" do
      pages = described_class::PAGES_PER_RUN + 1
      stub_paged_listing("wal_005/", pages)

      run_to_completion
      expect(state.wal_bytes).to eq(pages * 100)
      expect(state.cursor).to eq(format("wal_005/%06d", pages))
    end

    it "records no total, but backs off, when the walk is too large to finish" do
      stub_paged_listing("wal_005/", described_class::MAX_WALK_PAGES + described_class::PAGES_PER_RUN)

      expect(run_to_completion).to eq({"msg" => "wal walk exceeded #{described_class::MAX_WALK_PAGES} pages"})
      expect(Clog).to have_received(:emit).with("postgres backup metering walk abandoned", anything)
      expect(state.wal_bytes).to be_nil
      expect(PostgresBackupMeteringState.sweep_due?(timeline.id)).to be false
    end

    it "keeps the stored total, and backs off, when blob storage is unreachable" do
      create_ledger({cursor: wal_key(1), wal_bytes: 9, swept_at: Time.now - (2 * 60 * 60)})
      s3_client.stub_responses(:list_objects_v2,
        Aws::S3::Errors::NoSuchBucket.new(nil, "The specified bucket does not exist"))

      expect(run_to_completion).to eq({"msg" => "blob storage unavailable"})
      expect(Clog).to have_received(:emit).with("postgres backup metering blob storage error", anything)
      expect(state.wal_bytes).to eq(9)
      expect(PostgresBackupMeteringState.sweep_due?(timeline.id)).to be false
    end

    it "raises on an error that is not a blob storage failure" do
      s3_client.stub_responses(:list_objects_v2, "InternalError")

      expect { run_to_completion }.to raise_error(Strand::RunError)
      expect(state).to be_nil
    end
  end

  describe "#sweep_backups" do
    let(:sentinel) { object("basebackups_005/base_001_backup_stop_sentinel.json", 60, 10) }

    it "counts only objects belonging to a completed backup" do
      stub_listing(backups: [
        sentinel,
        object("basebackups_005/base_001/tar_partitions/part_001.tar.lz4", 60, 500),
        object("basebackups_005/base_002/tar_partitions/part_001.tar.lz4", 5, 900),
      ])

      run_to_completion
      expect(state.backup_bytes).to eq(510)
    end

    it "keeps the stored bytes when no new backup has landed" do
      started = Time.now - 3600
      timeline.update(latest_backup_started_at: started)
      create_ledger({backup_walked_at: Time.now, backup_bytes: 77, backup_started_seen: started})
      stub_listing(backups: [sentinel])

      run_to_completion
      expect(state.backup_bytes).to eq(77)
      expect(state.backup_walked_at).to be_within(1).of(Time.now - 1)
    end

    it "does not re-walk when the marker lost the sub-second part of the start" do
      # latest_backup_started_at carries microseconds, but the marker the walk
      # records is whole seconds, so the two only match once truncated. The
      # sentinel is newer than the start, so only that comparison can stop the
      # walk from running again on every sweep.
      started = Time.at(Time.now.to_i - (2 * 3600)) + 0.033553
      timeline.update(latest_backup_started_at: started)
      walked_at = Time.now - 600
      create_ledger({backup_walked_at: walked_at, backup_bytes: 77,
                     backup_started_seen: Time.at(started.to_i)})
      stub_listing(backups: [sentinel])

      run_to_completion
      expect(state.backup_bytes).to eq(77)
      expect(state.backup_walked_at).to be_within(1).of(walked_at)
    end

    it "defers the walk until the new backup writes its stop sentinel" do
      started = Time.now - 60
      timeline.update(latest_backup_started_at: started)
      create_ledger({backup_walked_at: Time.now, backup_bytes: 77, backup_started_seen: started - 3600})
      stub_listing(backups: [object("basebackups_005/base_001_backup_stop_sentinel.json", 120, 10)])

      run_to_completion
      expect(state.backup_bytes).to eq(77)
      expect(state.backup_started_seen).to be_within(1).of(started - 3600)
    end

    it "walks when the first backup lands after a walk that had no start to record" do
      started = Time.now - (2 * 3600)
      timeline.update(latest_backup_started_at: started)
      create_ledger({backup_walked_at: Time.now - 600, backup_bytes: 77, backup_started_seen: nil})
      stub_listing(backups: [sentinel])

      run_to_completion
      expect(state.backup_bytes).to eq(10)
      expect(state.backup_started_seen).to be_within(1).of(started)
    end

    it "walks once the sentinel is newer than the backup start" do
      started = Time.now - (2 * 3600)
      timeline.update(latest_backup_started_at: started)
      create_ledger({backup_walked_at: Time.now, backup_bytes: 77, backup_started_seen: started - 3600})
      stub_listing(backups: [sentinel])

      run_to_completion
      expect(state.backup_bytes).to eq(10)
      expect(state.backup_started_seen).to be_within(1).of(started)
    end

    it "re-walks after a day even when no new backup landed" do
      started = Time.now - (3 * 3600)
      timeline.update(latest_backup_started_at: started)
      create_ledger({backup_walked_at: Time.now - described_class::BACKUP_WALK_INTERVAL - 1,
                     backup_bytes: 77, backup_started_seen: started})
      stub_listing(backups: [sentinel])

      run_to_completion
      expect(state.backup_bytes).to eq(10)
    end

    it "records no total, but backs off, when the backup walk is too large to finish" do
      stub_backup_listing(sentinels: [sentinel],
        pages: described_class::MAX_WALK_PAGES + described_class::PAGES_PER_RUN)

      expect(run_to_completion).to eq({"msg" => "backup walk exceeded #{described_class::MAX_WALK_PAGES} pages"})
      expect(state.backup_bytes).to be_nil
      expect(PostgresBackupMeteringState.sweep_due?(timeline.id)).to be false
    end

    it "does not claim a backup issued while a chunked walk was running" do
      started = Time.now - (2 * 3600)
      timeline.update(latest_backup_started_at: started)
      stub_backup_listing(sentinels: [sentinel], pages: described_class::PAGES_PER_RUN + 1) do |served|
        # A new backup is issued part-way through the walk.
        timeline.update(latest_backup_started_at: Time.now) if served == 1
      end

      run_to_completion
      expect(state.backup_started_seen).to be_within(1).of(started)
    end

    it "keeps the stored total when the sentinel listing fails" do
      create_ledger({cursor: wal_key(1), wal_bytes: 9})
      s3_client.stub_responses(:list_objects_v2, lambda { |context|
        next {contents: [], is_truncated: false} if context.params[:prefix] == "wal_005/"

        raise Aws::S3::Errors::AccessDenied.new(nil, "AccessDenied")
      })

      expect(run_to_completion).to eq({"msg" => "blob storage unavailable"})
      expect(state.wal_bytes).to eq(9)
    end

    it "keeps the stored total when only the object walk fails" do
      create_ledger({cursor: wal_key(1), wal_bytes: 9})
      s3_client.stub_responses(:list_objects_v2, lambda { |context|
        next {contents: [], is_truncated: false} if context.params[:prefix] == "wal_005/"
        next {contents: [sentinel], is_truncated: false} if context.params[:delimiter] == "/"

        raise Aws::S3::Errors::AccessDenied.new(nil, "AccessDenied")
      })

      expect(run_to_completion).to eq({"msg" => "blob storage unavailable"})
      expect(state.wal_bytes).to eq(9)
      expect(state.backup_bytes).to be_nil
    end

    it "resumes a chunked backup walk from its token" do
      pages = described_class::PAGES_PER_RUN + 1
      stub_backup_listing(sentinels: [sentinel], pages:)

      run_to_completion
      expect(state.backup_bytes).to eq(pages * 100)
    end

    it "pages the sentinel listing, since is_permanent backups never expire" do
      second = object("basebackups_005/base_002_backup_stop_sentinel.json", 60, 20)
      served = 0
      s3_client.stub_responses(:list_objects_v2, lambda { |context|
        next {contents: [], is_truncated: false} if context.params[:prefix] == "wal_005/"
        unless context.params[:delimiter] == "/"
          next {contents: [object("basebackups_005/base_001/tar_partitions/part_1.tar.lz4", 60, 500)],
                is_truncated: false}
        end

        served += 1
        (served == 1) ? {contents: [sentinel], is_truncated: true, next_continuation_token: "next"} : {contents: [second], is_truncated: false}
      })

      run_to_completion
      expect(state.backup_bytes).to eq(500)
    end
  end

  describe "#finish" do
    it "drops day buckets older than the measured expiry boundary" do
      create_ledger({cursor: wal_key(1), wal_day_bytes: {"2020-01-01" => 999}})
      stub_listing(wal: [object(wal_key(1), 120, 100), object(wal_key(2), 120, 200)])
      day = (Time.now - 7200).utc.strftime("%Y-%m-%d")

      run_to_completion
      expect(state.wal_day_bytes.to_h).to eq({day => 200})
      expect(state.boundary_day.to_s).to eq(day)
    end

    it "does not take a .history file as the oldest surviving segment" do
      create_ledger({cursor: wal_key(2), wal_day_bytes: {"2020-01-01" => 999}})
      # Sorts before its own timeline's segments, since "." is below "0".
      stub_listing(wal: [object("wal_005/00000002.history.lz4", 5000, 50), object(wal_key(2), 120, 100)])

      run_to_completion
      expect(state.boundary_day.to_s).to eq((Time.now - 7200).utc.strftime("%Y-%m-%d"))
      expect(state.wal_day_bytes.to_h).to eq({})
    end

    it "reuses a fresh boundary instead of probing again" do
      create_ledger(
        {cursor: wal_key(9), boundary_probed_at: Time.now, boundary_day: Date.new(2020, 1, 1),
         wal_day_bytes: {"2020-01-01" => 999}, backup_walked_at: Time.now, backup_bytes: 5},
      )
      stub_listing(wal: [])

      run_to_completion
      expect(state.wal_day_bytes.to_h).to eq({"2020-01-01" => 999})
      expect(state.boundary_day).to eq(Date.new(2020, 1, 1))
    end

    it "caps the ledger when the bucket has no working expiry" do
      days = (1..(described_class::MAX_DAY_BUCKETS + 1)).to_h { [format("2020-01-%02d", it), it] }
      create_ledger({cursor: wal_key(9), boundary_probed_at: Time.now, wal_day_bytes: days})
      stub_listing(wal: [])

      run_to_completion
      expect(Clog).to have_received(:emit).with("postgres backup metering ledger over cap", anything)
      expect(state.wal_day_bytes.keys).to eq(days.keys.drop(1))
    end

    it "keeps the stored total when the expiry boundary probe fails" do
      create_ledger({cursor: wal_key(1), wal_bytes: 9, backup_walked_at: Time.now, backup_bytes: 3})
      # Only the probe lists without a cursor or a token, so this fails it alone.
      s3_client.stub_responses(:list_objects_v2, lambda { |context|
        params = context.params
        if params[:prefix] == "wal_005/" && params[:start_after].nil? && params[:continuation_token].nil?
          raise Aws::S3::Errors::AccessDenied.new(nil, "AccessDenied")
        end

        {contents: [], is_truncated: false}
      })

      expect(run_to_completion).to eq({"msg" => "blob storage unavailable"})
      expect(state.wal_bytes).to eq(9)
    end

    it "reports what it measured, and clears the reconcile request" do
      pg.incr_reconcile_backup_metering
      stub_listing(wal: [object(wal_key(1), 120, 100), object(wal_key(2), 120, 200)],
        backups: [object("basebackups_005/base_001_backup_stop_sentinel.json", 60, 10)])
      day = (Time.now - 7200).utc.strftime("%Y-%m-%d")

      run_to_completion
      expect(pg.reload.reconcile_backup_metering_set?).to be false
      expect(state.wal_bytes).to eq(300)
      expect(state.backup_bytes).to eq(10)
      # Clog.emit adds message and time to the hash it is handed, so match the
      # payload rather than the whole thing.
      expect(Clog).to have_received(:emit).with("postgres backup metering swept", hash_including(backup_metering: {
        resource_ubid: pg.ubid,
        timeline_ubid: timeline.ubid,
        wal_bytes: 300,
        wal_objects: 2,
        wal_days: 1,
        wal_pages: 1,
        backup_bytes: 10,
        backup_objects: 1,
        backup_pages: 1,
      }))
      expect(state.wal_day_bytes.to_h).to eq({day => 300})
    end
  end
end
