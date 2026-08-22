# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SyncArchivedRecords do
  subject(:prog) { described_class.new(strand) }

  let(:strand) { Strand.create(prog: "SyncArchivedRecords", label: "wait") }
  let(:time) { Time.utc(2026, 8, 20, 12, 0, 0) }
  let(:archive_url) {
    separator = Config.clover_database_url.include?("?") ? "&" : "?"
    "#{Config.clover_database_url}#{separator}search_path=archived_record_sync_test"
  }

  def archive_db(&)
    Sequel.connect(archive_url, max_connections: 1, &)
  end

  def seed_archive(last_archived_at)
    archive_db do |db|
      db.create_table(:archived_record, partition_by: :archived_at, partition_type: :range) do
        column :archived_at, :timestamptz, null: false
        column :model_name, :text, null: false
        column :model_values, :jsonb, null: false
      end
      db.create_table(:archived_record_sync_state) do
        column :last_archived_at, :timestamptz, null: false
      end
      db[:archived_record_sync_state].insert(last_archived_at:)
    end
  end

  def insert_local(archived_at)
    DB[:archived_record].insert(archived_at:, model_name: "Vm", model_values: Sequel.pg_jsonb({"id" => "x"}))
  end

  describe "#wait" do
    it "registers a deadline and hops to sync when it has not synced before" do
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      expect { prog.wait }.to hop("sync")
      expect(strand.stack.first["deadline_target"]).to eq("wait")
      expect(strand.stack.first["deadline_at"]).to eq(strand.time_string(time + 48 * 60 * 60))
    end

    it "naps until a day has passed since the last successful sync" do
      strand.update(stack: [{"last_success_at" => time.to_s}])
      expect(Time).to receive(:now).and_return(time + 3600).at_least(:once)
      expect { prog.wait }.to nap(82801)
    end

    it "hops to sync when a day has passed since the last successful sync" do
      strand.update(stack: [{"last_success_at" => time.to_s}])
      expect(Time).to receive(:now).and_return(time + 24 * 60 * 60 + 1).at_least(:once)
      expect { prog.wait }.to hop("sync")
    end
  end

  describe "#sync" do
    before do
      # Non-transactional specs can leave committed archived_record rows behind.
      DB[:archived_record].delete
      Sequel.connect(Config.clover_database_url, max_connections: 1) do |db|
        db.run "DROP SCHEMA IF EXISTS archived_record_sync_test CASCADE"
        db.run "CREATE SCHEMA archived_record_sync_test"
      end
      allow(Config).to receive(:archive_database_url).and_return(archive_url)
    end

    after do
      Sequel.connect(Config.clover_database_url, max_connections: 1) do |db|
        db.run "DROP SCHEMA IF EXISTS archived_record_sync_test CASCADE"
      end
    end

    it "bootstraps the archive, copies settled rows, and prunes fully archived partitions" do
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      insert_local(time - 2 * 24 * 60 * 60)
      insert_local(time - 24 * 60 * 60)
      insert_local(time - 60)

      expect { prog.sync }.to hop("wait")
        .and change { strand.stack.first["last_success_at"] }.from(nil).to(time.to_s)

      archive_db do |db|
        expect(db[:archived_record].count).to eq(2)
        expect(db[:archived_record_sync_state].get(:last_archived_at)).to eq(time - 60 * 60)
        expect(db.get(Sequel.function(:to_regclass, "archived_record_2026_08"))).not_to be_nil
        expect(db.get(Sequel.function(:to_regclass, "archived_record_2026_10"))).not_to be_nil
      end
      expect(DB.get(Sequel.function(:to_regclass, "archived_record_2026_05"))).to be_nil
      expect(DB.get(Sequel.function(:to_regclass, "archived_record_2026_08"))).not_to be_nil
      settled_cutoff = time - 60 * 60
      expect(DB[:archived_record].where { archived_at > settled_cutoff }.count).to eq(1)
    end

    it "seeds the high-water mark a lag behind the current time when there are no local rows" do
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      DB.create_table("archived_record_extra", partition_of: :archived_record) do
        from Date.new(2020, 1, 1)
        to Date.new(2020, 2, 1)
      end
      Prog::PageNexus.assemble("test drift", ["ArchivedRecordSyncSchemaDrift"], nil)

      expect { prog.sync }.to hop("wait")

      archive_db do |db|
        expect(db[:archived_record].count).to eq(0)
        expect(db[:archived_record_sync_state].get(:last_archived_at)).to eq(time - 60 * 60)
      end
      expect(DB.get(Sequel.function(:to_regclass, "archived_record_extra"))).not_to be_nil
      drift_page = Page.from_tag_parts("ArchivedRecordSyncSchemaDrift")
      expect(Semaphore.where(strand_id: drift_page.id, name: "resolve").count).to eq(1)
    end

    it "pages and pauses when the archived_record schema drifts" do
      seed_archive(time - 60 * 60)
      archive_db { |db| db.alter_table(:archived_record) { add_column :extra, :text } }

      expect { prog.sync }.to nap(6 * 60 * 60)

      expect(Page.from_tag_parts("ArchivedRecordSyncSchemaDrift")).not_to be_nil
    end

    it "creates missing local partitions ahead of time" do
      future = Time.utc(2026, 11, 15)
      expect(Time).to receive(:now).and_return(future).at_least(:once)

      expect { prog.sync }.to hop("wait")

      expect(DB.get(Sequel.function(:to_regclass, "archived_record_2027_01"))).not_to be_nil
      archive_db do |db|
        expect(db.get(Sequel.function(:to_regclass, "archived_record_2027_01"))).not_to be_nil
      end
    end

    if Config.unfrozen_test?
      it "bisects oversized windows and copies boundary ties in one batch" do
        stub_const("Prog::SyncArchivedRecords::MAX_COPY_ROWS", 2)
        base = Time.now - 60 * 60 - 9
        seed_archive(base - 1)
        insert_local(base + 0.5)
        insert_local(base + 0.5)
        insert_local(base + 0.5)
        insert_local(base + 5)
        insert_local(base + 6)

        expect { prog.sync }.to hop("wait")

        archive_db do |db|
          expect(db[:archived_record].count).to eq(5)
          expect(db[:archived_record_sync_state].get(:last_archived_at)).to be > base + 6
        end
      end

      it "verifies a large partition in slices across runs before dropping it" do
        stub_const("Prog::SyncArchivedRecords::MAX_COPY_ROWS", 2)
        stub_const("Prog::SyncArchivedRecords::VERIFY_SLICE", 6 * 24 * 60 * 60)
        expect(Time).to receive(:now).and_return(time).at_least(:once)
        seed_archive(time - 60 * 60)
        row_times = Array.new(3) { |i| Time.utc(2026, 5, 10 + i * 7) }
        row_times.each { insert_local(it) }
        archive_db do |db|
          db.create_table("archived_record_2026_05", partition_of: :archived_record) do
            from Date.new(2026, 5, 1)
            to Date.new(2026, 6, 1)
          end
          row_times.each { |t| db[:archived_record].insert(archived_at: t, model_name: "Vm", model_values: Sequel.pg_jsonb({"id" => "x"})) }
        end

        expect { prog.sync }.to nap(10)
        expected_verified_through = DB.get(Sequel.cast(Date.new(2026, 5, 1), :timestamptz)) + 24 * 24 * 60 * 60
        archive_db do |db|
          expect(db[:archived_record_prune_state].get(:verified_through)).to eq(expected_verified_through)
        end
        expect { prog.sync }.to hop("wait")

        expect(DB.get(Sequel.function(:to_regclass, "archived_record_2026_05"))).to be_nil
        archive_db { |db| expect(db[:archived_record_prune_state].count).to eq(0) }
      end

      it "pages after sliced verification when the archive holds extra rows" do
        stub_const("Prog::SyncArchivedRecords::MAX_COPY_ROWS", 2)
        stub_const("Prog::SyncArchivedRecords::VERIFY_SLICE", 10 * 24 * 60 * 60)
        expect(Time).to receive(:now).and_return(time).at_least(:once)
        seed_archive(time - 60 * 60)
        insert_local(Time.utc(2026, 5, 10))
        archive_db do |db|
          db.create_table("archived_record_2026_05", partition_of: :archived_record) do
            from Date.new(2026, 5, 1)
            to Date.new(2026, 6, 1)
          end
          3.times { db[:archived_record].insert(archived_at: Time.utc(2026, 5, 10), model_name: "Vm", model_values: Sequel.pg_jsonb({"id" => "x"})) }
        end

        expect { prog.sync }.to hop("wait")

        expect(DB.get(Sequel.function(:to_regclass, "archived_record_2026_05"))).not_to be_nil
        expect(Page.from_tag_parts("ArchivedRecordSyncMismatch", "archived_record_2026_05")).not_to be_nil
        archive_db { |db| expect(db[:archived_record_prune_state].count).to eq(0) }
      end
    end

    it "naps to continue copying and refreshes the stall deadline when the window budget is exhausted" do
      seed_archive(Time.now - 60 * 60 - 9 * 24 * 60 * 60)

      expect { prog.sync }.to nap(10)
      expect(strand.stack.first["deadline_target"]).to eq("wait")
      expect(strand.stack.first["deadline_at"]).not_to be_nil
    end

    it "finishes without an extra nap when copying ends exactly at the window budget" do
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      seed_archive(time - 60 * 60 - 8 * 24 * 60 * 60)

      expect { prog.sync }.to hop("wait")

      archive_db do |db|
        expect(db[:archived_record_sync_state].get(:last_archived_at)).to eq(time - 60 * 60)
      end
    end

    it "refuses to advance the mark from a stale window" do
      seed_archive(time)
      archive_db do |db|
        expect { prog.send(:copy_window, db, time - 10, time - 5) }
          .to raise_error(RuntimeError, /sync state advanced concurrently/)
        expect(db[:archived_record_sync_state].get(:last_archived_at)).to eq(time)
      end
    end

    it "drops a partition with rows once the archive matches and resolves the mismatch page" do
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      seed_archive(time - 60 * 60)
      insert_local(Time.utc(2026, 5, 10))
      Prog::PageNexus.assemble("test mismatch", ["ArchivedRecordSyncMismatch", "archived_record_2026_05"], nil)
      archive_db do |db|
        db.create_table("archived_record_2026_05", partition_of: :archived_record) do
          from Date.new(2026, 5, 1)
          to Date.new(2026, 6, 1)
        end
        db[:archived_record].insert(archived_at: Time.utc(2026, 5, 10), model_name: "Vm", model_values: Sequel.pg_jsonb({"id" => "x"}))
      end

      expect { prog.sync }.to hop("wait")

      expect(DB.get(Sequel.function(:to_regclass, "archived_record_2026_05"))).to be_nil
      page = Page.from_tag_parts("ArchivedRecordSyncMismatch", "archived_record_2026_05")
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
    end

    it "pages instead of dropping a partition whose rows are not all archived" do
      expect(Time).to receive(:now).and_return(time).at_least(:once)
      seed_archive(time - 60 * 60)
      insert_local(Time.utc(2026, 5, 10))

      expect { prog.sync }.to hop("wait")

      expect(DB.get(Sequel.function(:to_regclass, "archived_record_2026_05"))).not_to be_nil
      expect(Page.from_tag_parts("ArchivedRecordSyncMismatch", "archived_record_2026_05")).not_to be_nil
    end
  end
end
