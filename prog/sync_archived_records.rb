# frozen_string_literal: true

class Prog::SyncArchivedRecords < Prog::Base
  frame_accessor :last_success_at

  SYNC_INTERVAL = 24 * 60 * 60
  STALL_DEADLINE = 48 * 60 * 60
  COPY_LAG = 60 * 60
  COPY_WINDOW = 24 * 60 * 60
  MAX_WINDOWS_PER_RUN = 8
  MAX_COPY_ROWS = 10_000
  LOCAL_RETENTION_MONTHS = 1
  PARTITIONS_AHEAD = 2
  VERIFY_SLICE = 24 * 60 * 60
  MAX_VERIFY_SLICES_PER_RUN = 4
  COPY_COLUMNS = [:archived_at, :model_name, :model_values].freeze

  label def wait
    if last_success_at
      remaining_seconds = SYNC_INTERVAL - (Time.now - Time.new(last_success_at))
      nap remaining_seconds.to_i + 1 if remaining_seconds > 0
    end
    register_deadline("wait", STALL_DEADLINE)
    hop_sync
  end

  label def sync
    Sequel.connect(Config.archive_database_url, max_connections: 1) do |adb|
      adb.extension(:pg_json, :pg_timestamptz)
      # Month boundaries are cast in the session timezone on both sides.
      adb.run("SET TIME ZONE #{adb.literal(DB.get(Sequel.function(:current_setting, "TimeZone")))}")
      setup_archive(adb)
      check_schema(adb)
      ensure_partitions(adb)
      unless copy(adb) && prune(adb)
        # More work remains and the mark or the verification advanced, so the
        # stall deadline measures lack of progress, not completion: a backfill
        # at production scale legitimately runs for days.
        unregister_deadline("wait")
        register_deadline("wait", STALL_DEADLINE)
        nap 10
      end
    end
    self.last_success_at = Time.now.to_s
    hop_wait
  end

  private

  def setup_archive(adb)
    unless table_exists?(adb, "archived_record")
      adb.create_table(:archived_record, partition_by: :archived_at, partition_type: :range) do
        column :archived_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
        column :model_name, :text, null: false
        column :model_values, :jsonb, null: false, default: "{}"
        index [:model_name, :archived_at]
        index :archived_at
      end
    end

    unless table_exists?(adb, "archived_record_sync_state")
      adb.create_table(:archived_record_sync_state) do
        column :last_archived_at, :timestamptz, null: false
      end
    end

    unless table_exists?(adb, "archived_record_prune_state")
      adb.create_table(:archived_record_prune_state) do
        column :partition_name, :text, primary_key: true
        column :verified_through, :timestamptz, null: false
        column :local_rows, :bigint, null: false
        column :archive_rows, :bigint, null: false
      end
    end

    if adb[:archived_record_sync_state].empty?
      # The lag keeps rows of destroys in flight at bootstrap ahead of the
      # initial mark, the same bound the copy gives them afterwards.
      first_archived_at = DB[:archived_record].min(:archived_at) || Time.now
      adb[:archived_record_sync_state].insert(last_archived_at: first_archived_at - COPY_LAG)
    end
  end

  # Model schema changes travel inside model_values and need nothing here;
  # a change to the envelope itself must not be papered over: copying a
  # subset would let prune drop partitions whose new column was never
  # archived, so both sides must match the pinned list before any work.
  def check_schema(adb)
    local_columns = DB[:archived_record].columns.sort
    archive_columns = adb[:archived_record].columns.sort
    if local_columns == COPY_COLUMNS.sort && archive_columns == COPY_COLUMNS.sort
      Page.from_tag_parts("ArchivedRecordSyncSchemaDrift")&.incr_resolve
    else
      Prog::PageNexus.assemble("archived_record schema drifted from the sync column list (local: #{local_columns.join(", ")}; archive: #{archive_columns.join(", ")})", ["ArchivedRecordSyncSchemaDrift"], nil)
      nap 6 * 60 * 60
    end
  end

  def ensure_partitions(adb)
    hwm = adb[:archived_record_sync_state].get(:last_archived_at)
    now = Time.now
    last_month = Date.new(now.year, now.month).next_month(PARTITIONS_AHEAD)
    ensure_partition_range(adb, Date.new(hwm.year, hwm.month), last_month)
    ensure_partition_range(DB, Date.new(now.year, now.month), last_month)
  end

  def ensure_partition_range(db, month, last_month)
    while month <= last_month
      name = partition_name(month)
      unless table_exists?(db, name)
        db.create_table(name, partition_of: :archived_record) do
          from month
          to month.next_month
        end
      end
      month = month.next_month
    end
  end

  def copy(adb)
    cutoff = Time.now - COPY_LAG
    hwm = adb[:archived_record_sync_state].get(:last_archived_at)
    span = COPY_WINDOW
    MAX_WINDOWS_PER_RUN.times do
      return true if hwm >= cutoff
      new_hwm = copy_window(adb, hwm, [hwm + span, cutoff].min)
      # Remember how much of the window survived bisection and probe upwards,
      # so steady heavy traffic pays one bisection per run, not one per window.
      span = [(new_hwm - hwm) * 2, COPY_WINDOW].min
      hwm = new_hwm
    end
    hwm >= cutoff
  end

  # Rows and the high-water mark commit in one archive-side transaction and
  # the local side is only read, so a crash reruns the window without
  # duplicating or losing rows.
  def copy_window(adb, from, to)
    ds = nil
    loop do
      ds = DB[:archived_record].select(*COPY_COLUMNS).where { (archived_at > from) & (archived_at <= to) }
      break if to - from <= 1 || ds.count <= MAX_COPY_ROWS
      to = from + (to - from) / 2
    end
    rows = ds.all
    adb.transaction do
      rows.each_slice(1000) { adb[:archived_record].multi_insert(it) }
      # Compare-and-set with the mark as the optimistic concurrency control
      # key: a worker that lost its lease past an already-synced window fails
      # here and rolls its duplicate inserts back.
      unless adb[:archived_record_sync_state].where(last_archived_at: from).update(last_archived_at: to) == 1
        fail "archived_record sync state advanced concurrently"
      end
    end
    to
  end

  def prune(adb)
    keep_from = Date.new(Time.now.year, Time.now.month).prev_month(LOCAL_RETENTION_MONTHS)
    local_partitions.sort_by { |_, month| month }.each do |name, month|
      next if month >= keep_from
      return false unless verify_and_drop(adb, name, month)
    end
    true
  end

  def verify_and_drop(adb, name, month)
    month_start = month_bound(month)
    month_end = month_bound(month.next_month)
    state_ds = adb[:archived_record_prune_state].where(partition_name: name)

    unless (state = state_ds.first)
      probe = MAX_COPY_ROWS + 1
      local_rows = DB.from(name).limit(probe).from_self.count
      archive_rows = adb[:archived_record].where { (archived_at >= month_start) & (archived_at < month_end) }.limit(probe).from_self.count
      if local_rows <= MAX_COPY_ROWS && archive_rows <= MAX_COPY_ROWS
        return conclude_verification(name, local_rows, archive_rows)
      end
      state = {partition_name: name, verified_through: month_start, local_rows: 0, archive_rows: 0}
      state_ds.insert(state)
    end

    verified_through = state[:verified_through]
    local_rows = state[:local_rows]
    archive_rows = state[:archive_rows]
    slices = 0
    while verified_through < month_end
      return false if slices == MAX_VERIFY_SLICES_PER_RUN
      slice_end = [verified_through + VERIFY_SLICE, month_end].min
      local_rows += DB.from(name).where { (archived_at >= verified_through) & (archived_at < slice_end) }.count
      archive_rows += adb[:archived_record].where { (archived_at >= verified_through) & (archived_at < slice_end) }.count
      state_ds.update(verified_through: slice_end, local_rows:, archive_rows:)
      verified_through = slice_end
      slices += 1
    end
    state_ds.delete
    conclude_verification(name, local_rows, archive_rows)
  end

  # Copies never duplicate and only draw from local rows, so equal counts
  # imply every row of the partition is archived.
  def conclude_verification(name, local_rows, archive_rows)
    if local_rows == archive_rows
      Page.from_tag_parts("ArchivedRecordSyncMismatch", name)&.incr_resolve
      DB.run "SET LOCAL lock_timeout = '5s'"
      DB.drop_table(name)
    else
      Prog::PageNexus.assemble("archived_record partition #{name} has #{local_rows} local rows but #{archive_rows} archived rows", ["ArchivedRecordSyncMismatch", name], nil)
    end
    true
  end

  def local_partitions
    DB[:pg_inherits]
      .join(:pg_class, oid: :inhrelid)
      .where(inhparent: Sequel.cast("archived_record", :regclass))
      .select_map(:relname)
      .filter_map do |name|
        if (md = /\Aarchived_record_(\d{4})_(\d{2})\z/.match(name))
          [name, Date.new(md[1].to_i, md[2].to_i)]
        end
      end
  end

  def partition_name(month)
    "archived_record_#{month.strftime("%Y_%m")}"
  end

  def month_bound(month)
    DB.get(Sequel.cast(month, :timestamptz))
  end

  def table_exists?(db, name)
    !db.get(Sequel.function(:to_regclass, name)).nil?
  end
end
