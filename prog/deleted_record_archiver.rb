# frozen_string_literal: true

require "aws-sdk-s3"
require "tempfile"
require "zlib"

class Prog::DeletedRecordArchiver < Prog::Base
  COLUMNS = [:deleted_at, :model_name, :record_id, :model_values].freeze
  COPY_TIMEOUT = "30s"
  WINDOW_SECONDS = 60 * 60
  WRITE_BUFFER_BYTES = 64 * 1024
  STALL_DEADLINE = 3 * 60 * 60
  MANIFEST_RETENTION_DAYS = 365

  label def wait
    hop_drop_unarchived if drop_unarchived?
    nap 60 * 60 unless Config.deleted_record_archive_bucket

    if next_action
      register_deadline("wait", STALL_DEADLINE)
      hop_archive
    end

    nap 5 * 60
  end

  label def archive
    action, subject = next_action

    case action
    when :open
      open_day(subject)
    when :upload
      upload_next_slice(subject)
    when :verify
      verify_day(subject)
      hop_wait
    when :drop
      hop_drop_oldest_partition
    when :prune
      prune_day(subject)
    else
      hop_wait
    end

    nap 1
  end

  label def drop_oldest_partition
    day_row = droppable_day
    hop_wait unless day_row

    day = day_row[:day]
    if (exists = DeletedRecord.partition_days.include?(day))
      begin
        DB.transaction(savepoint: true) do
          DeletedRecord.drop_partition(day)
        end
      rescue Sequel::DatabaseLockTimeout
        Clog.emit("deleted_record partition drop timed out", {deleted_record_drop_timeout: {day:}})
        nap 60
      end
    end

    DB[:deleted_record_archive].where(day:).update(dropped_at: Sequel::CURRENT_TIMESTAMP)

    Clog.emit("dropped deleted_record partition", {deleted_record_partition_dropped: {day:, existed: exists}})
    hop_wait
  end

  label def drop_unarchived
    day = expired_day
    hop_wait unless day

    DeletedRecord.drop_partition(day)
    Clog.emit("dropped unarchived deleted_record partition", {deleted_record_partition_dropped: {day:}})
    hop_wait
  end

  def drop_unarchived?
    Config.deleted_record_archive_bucket.nil? && Config.development? && !expired_day.nil?
  end

  def expired_day
    DeletedRecord.partition_days.find { it < Time.now.utc.to_date - DeletedRecord::RETENTION_DAYS }
  end

  def next_action
    if (day_row = incomplete_day)
      [(archived_through(day_row[:day]) < day_end(day_row[:day])) ? :upload : :verify, day_row]
    elsif (day_row = droppable_day)
      [:drop, day_row]
    elsif (day = next_day_to_open)
      [:open, day]
    elsif (day_row = prunable_day)
      [:prune, day_row]
    end
  end

  def next_day_to_open
    opened = DB[:deleted_record_archive].select_map(:day).to_set
    day = DeletedRecord.partition_days.find { !opened.include?(it) }
    day if day && Time.now.utc >= day_end(day) + 60 * 60
  end

  def incomplete_day
    DB[:deleted_record_archive].where(verified_at: nil).order(:day).first
  end

  def droppable_day
    DB[:deleted_record_archive]
      .exclude(verified_at: nil)
      .where(dropped_at: nil)
      .where(Sequel[:day] < Time.now.utc.to_date - DeletedRecord::RETENTION_DAYS)
      .order(:day)
      .first
  end

  def prunable_day
    DB[:deleted_record_archive]
      .exclude(dropped_at: nil)
      .where(Sequel[:day] < Time.now.utc.to_date - MANIFEST_RETENTION_DAYS)
      .order(:day)
      .first
  end

  def prune_day(day_row)
    day = day_row[:day]
    slices = DB[:deleted_record_archive_slice].where(day:).count
    DB[:deleted_record_archive].where(day:).delete
    Clog.emit("pruned deleted_record archive manifest", {deleted_record_manifest_pruned: {day:, slices:}})
  end

  def open_day(day)
    index = DB[Sequel[:pg_index].as(:i)]
      .join(Sequel[:pg_class].as(:c), oid: Sequel[:i][:indexrelid])
      .join(Sequel[:pg_am].as(:a), oid: Sequel[:c][:relam])
      .where(Sequel[:i][:indrelid] => Sequel.cast(DeletedRecord.partition_name(day), :regclass), Sequel[:a][:amname] => "brin")
      .get(Sequel[:c][:relname])
    ranges = DB.get(Sequel.function(:brin_summarize_new_values, Sequel.cast(index, :regclass)))
    Clog.emit("summarized deleted_record brin ranges", {deleted_record_brin_summarized: {day:, ranges:}})
    DB[:deleted_record_archive].insert(day:)
    Clog.emit("opened deleted_record archive day", {deleted_record_archive_opened: {day:}})
  end

  def upload_next_slice(day_row)
    day = day_row[:day]
    window_from = archived_through(day)

    next_hour = window_from + WINDOW_SECONDS - (window_from.to_i % WINDOW_SECONDS)
    window_to = [next_hour, day_end(day)].min
    key = object_key(day, window_from, window_to)

    DB.run("SET LOCAL TimeZone = 'UTC'")
    DB.get(Sequel.function(:set_config, "statement_timeout", COPY_TIMEOUT, true))

    rows = 0
    ds = DB[partition(day)]
      .where(deleted_at: window_from...window_to)
      .select(*COLUMNS.map { (it == :model_values) ? Sequel.cast(it, :text) : it })

    Tempfile.create("deleted-record-archive") do |file|
      file.binmode
      gz = Zlib::GzipWriter.new(file, Zlib::BEST_SPEED)

      buffer = "".b
      DB.copy_table(ds, format: :csv) do |chunk|
        rows += 1
        buffer << chunk
        if buffer.bytesize >= WRITE_BUFFER_BYTES
          gz.write(buffer)
          buffer.clear
        end
      end
      gz.write(buffer) unless buffer.empty?

      gz.finish
      file.flush
      bytes = file.size
      file.rewind

      etag = blob_storage_client.put_object(
        bucket: Config.deleted_record_archive_bucket,
        key:,
        body: file,
        content_length: bytes,
        content_type: "application/gzip",
        checksum_algorithm: "CRC32",
      ).etag

      period = Sequel.pg_range(window_from...window_to, :tstzrange)
      DB[:deleted_record_archive_slice].insert(day:, period:, object_key: key, row_count: rows, bytes:, etag:)

      Clog.emit("archived deleted_record slice", {deleted_record_slice_archived: {day:, key:, rows:, bytes:}})
    end
  end

  def archived_through(day)
    DB[:deleted_record_archive_slice].where(day:).max(Sequel.function(:upper, :period)) || day_start(day)
  end

  def verify_day(day_row)
    day = day_row[:day]
    archived_rows = DB[:deleted_record_archive_slice].where(day:).sum(:row_count).to_i
    partition_rows = DB[partition(day)].count

    unless archived_rows == partition_rows
      Prog::PageNexus.assemble(
        "deleted_record archive for #{day} does not match its partition",
        ["DeletedRecordArchiveMismatch", day.to_s],
        strand.ubid,
        extra_data: {archived_rows:, partition_rows:},
      )
      nap 15 * 60
    end

    DB[:deleted_record_archive].where(day:).update(verified_at: Sequel::CURRENT_TIMESTAMP)
    Page.from_tag_parts("DeletedRecordArchiveMismatch", day.to_s)&.incr_resolve
    Clog.emit("verified deleted_record archive day", {deleted_record_archive_verified: {day:, rows: partition_rows}})
  end

  def object_key(day, window_from, window_to)
    from_label = window_from.utc.strftime("%H%M")

    to_label = (window_to == day_end(day)) ? "2400" : window_to.utc.strftime("%H%M")
    "date=#{day}/#{from_label}-#{to_label}.csv.gz"
  end

  def partition(day)
    :"#{DeletedRecord.partition_name(day)}"
  end

  def day_start(day)
    Time.utc(day.year, day.month, day.day)
  end

  def day_end(day)
    day_start(day) + (24 * 60 * 60)
  end

  def blob_storage_client
    @blob_storage_client ||= self.class.new_blob_storage_client
  end

  def self.new_blob_storage_client
    Aws::S3::Client.new(
      endpoint: Config.deleted_record_archive_endpoint,
      access_key_id: Config.deleted_record_archive_access_key,
      secret_access_key: Config.deleted_record_archive_secret_key,
      region: "us-east-1",
      force_path_style: true,
      http_open_timeout: 5,
      http_read_timeout: 10,
      retry_limit: 0,
      request_checksum_calculation: "when_required",
      response_checksum_validation: "when_required",
    )
  end
end
