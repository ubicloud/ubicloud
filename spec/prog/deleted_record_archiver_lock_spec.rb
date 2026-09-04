# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DeletedRecordArchiver, :no_db_transaction do
  subject(:prog) {
    described_class.new(Strand.create_with_id(strand_id, prog: "DeletedRecordArchiver", label: "wait"))
  }

  let(:strand_id) { UBID.parse("stde1etedrecyarch1verzzzzy").to_uuid }
  let(:day) { Time.now.utc.to_date - DeletedRecord::RETENTION_DAYS - 1 }

  def clean_up
    DB[:deleted_record_archive_slice].where(day:).delete
    DB[:deleted_record_archive].where(day:).delete
    DeletedRecord.drop_partition(day) if DeletedRecord.partition_days.include?(day)
    Strand.where(id: strand_id).destroy
  end

  before do
    clean_up
    DeletedRecord.create_partition(day)
    DB[:deleted_record_archive].insert(day:, verified_at: Time.now)
  end

  after { clean_up }

  def await(ready, thread)
    return if ready.pop(timeout: 10)

    thread.join(5)
    raise "thread never signalled ready"
  end

  it "gives up a contended drop rather than queueing destroys behind it" do
    reader_ready = Queue.new
    reader_release = Queue.new
    reader = Thread.new do
      DB.transaction do
        DB.run("LOCK TABLE deleted_record IN ACCESS SHARE MODE")
        reader_ready.push(true)
        reader_release.pop
      end
    end

    begin
      await(reader_ready, reader)
      DB.transaction(savepoint: true) do
        expect { prog.drop_oldest_partition }.to nap(60)
        expect { prog.strand.this.update(schedule: Sequel::CURRENT_TIMESTAMP) }.not_to raise_error
      end
      expect(DeletedRecord.partition_days).to include(day)
      expect(DB[:deleted_record_archive].first(day:)[:dropped_at]).to be_nil
    ensure
      reader_release.push(true)
      reader.join(5)
    end

    expect { prog.drop_oldest_partition }.to hop("wait")
      .and change { DB[:deleted_record_archive].first(day:)[:dropped_at] }.from(nil)
    expect(DeletedRecord.partition_days).not_to include(day)
  end

  it "extends the runway without waiting for a destroy in flight" do
    future = Time.now.utc.to_date + 200
    writer_ready = Queue.new
    writer_release = Queue.new
    writer = Thread.new do
      DB.transaction(rollback: :always) do
        DB[:deleted_record].insert(model_name: "Vm", model_values: Sequel.pg_jsonb({}))
        writer_ready.push(true)
        writer_release.pop
      end
    end

    begin
      await(writer_ready, writer)
      started = Time.now
      DeletedRecord.create_partition(future)
      expect(Time.now - started).to be < 1
      expect(DeletedRecord.partition_days).to include(future)
    ensure
      writer_release.push(true)
      writer.join(5)
      DeletedRecord.drop_partition(future) if DeletedRecord.partition_days.include?(future)
    end
  end

  it "does not hold the parent lock while a reader is waiting for it" do
    expect { prog.drop_oldest_partition }.to hop("wait")

    started = Time.now
    reader = Thread.new { DB.transaction { DB.run("LOCK TABLE deleted_record IN ACCESS SHARE MODE") } }
    reader.join(5)
    expect(Time.now - started).to be < 1
  end
end
