# frozen_string_literal: true

class Prog::Postgres::BackupMetering < Prog::Base
  subject_is :postgres_resource

  frame_accessor :walk_token, :walk_pages, :wal_cursor, :wal_day_bytes,
    :wal_objects, :wal_pages, :backup_bytes, :backup_objects, :backup_started_seen

  WAL_PREFIX = "wal_005/"
  BACKUP_PREFIX = "basebackups_005/"
  SENTINEL_SUFFIX = "_backup_stop_sentinel.json"

  # wal-g uploads concurrently, so a lower-keyed segment can land after a
  # higher-keyed one. A segment delayed past this is counted once or not at all.
  CURSOR_LAG = 5 * 60
  BOUNDARY_PROBE_INTERVAL = 6 * 60 * 60
  BACKUP_WALK_INTERVAL = 24 * 60 * 60
  # The dispatcher gives a strand 30s per pickup.
  PAGES_PER_RUN = 50
  # Bounds the ledger if a bucket ever loses its lifecycle policy.
  MAX_DAY_BUCKETS = 30
  # A budget, not a limit: past this, keep the last good total.
  MAX_WALK_PAGES = 2000

  label def start
    pop "backup metering disabled" unless Config.postgres_backup_metering_enabled
    pop "not metered" unless timeline

    reconciling = postgres_resource.reconcile_backup_metering_set?
    self.wal_cursor = reconciling ? nil : state&.cursor
    self.wal_day_bytes = reconciling ? {} : (state&.wal_day_bytes&.to_h || {})
    self.wal_objects = 0
    self.walk_token = nil
    self.walk_pages = 0
    hop_sweep_wal
  end

  label def sweep_wal
    days = wal_day_bytes
    cursor = wal_cursor
    token = walk_token
    pages = walk_pages
    objects_counted = wal_objects
    cutoff = Time.now - CURSOR_LAG
    complete = false
    run_pages = 0

    until complete || run_pages == PAGES_PER_RUN
      objects, token = list_page(WAL_PREFIX, cursor, token)
      run_pages += 1
      pages += 1

      objects.each do |object|
        # Peers may still be uploading below its key, so do not advance past it.
        if object.last_modified >= cutoff
          complete = true
          break
        end

        day = object.last_modified.utc.strftime("%Y-%m-%d")
        days[day] = days[day].to_i + object.size
        cursor = object.key
        objects_counted += 1
      end

      complete ||= token.nil?
    end

    back_off "wal walk exceeded #{MAX_WALK_PAGES} pages" if abandon_walk?(WAL_PREFIX, pages)

    self.wal_day_bytes = days
    self.wal_cursor = cursor
    self.wal_objects = objects_counted
    self.walk_token = token
    self.walk_pages = pages
    nap 0 unless complete

    self.wal_pages = pages
    self.walk_token = nil
    self.walk_pages = 0
    hop_sweep_backups
  rescue => ex
    swallow_blob_storage_error(ex)
  end

  label def sweep_backups
    hop_finish unless !backup_bytes.nil? || backup_walk_due?

    # Pinned at the start of the walk: a backup issued mid-walk is not in what
    # the walk measured, so recording it would skip it until the 24 hour floor.
    self.backup_started_seen = timeline.latest_backup_started_at&.to_i if backup_bytes.nil?

    # A base_<name>/ with no sentinel is an interrupted backup-push: backup-list
    # never shows one and no restore can use it, so it is not billed.
    completed = Set.new(sentinels) { backup_name(it.key) }
    bytes = backup_bytes.to_i
    objects_counted = backup_objects.to_i
    token = walk_token
    pages = walk_pages
    complete = false
    run_pages = 0

    until complete || run_pages == PAGES_PER_RUN
      objects, token = list_page(BACKUP_PREFIX, nil, token)
      run_pages += 1
      pages += 1

      objects.each do |object|
        next unless completed.include?(backup_name(object.key))

        bytes += object.size
        objects_counted += 1
      end

      complete = token.nil?
    end

    back_off "backup walk exceeded #{MAX_WALK_PAGES} pages" if abandon_walk?(BACKUP_PREFIX, pages)

    self.backup_bytes = bytes
    self.backup_objects = objects_counted
    self.walk_token = token
    self.walk_pages = pages
    nap 0 unless complete

    hop_finish
  rescue => ex
    swallow_blob_storage_error(ex)
  end

  label def finish
    boundary_day, boundary_probed_at = wal_expiry_boundary
    days = expire_day_buckets(wal_day_bytes, boundary_day)
    total = days.values.sum
    walked_backups = !backup_bytes.nil?

    values = {
      swept_at: Time.now,
      cursor: wal_cursor,
      wal_bytes: total,
      wal_day_bytes: Sequel.pg_jsonb(days),
      boundary_day:,
      boundary_probed_at:,
    }
    if walked_backups
      values[:backup_bytes] = backup_bytes
      values[:backup_walked_at] = Time.now
      values[:backup_started_seen] = backup_started_seen && Time.at(backup_started_seen)
    end
    PostgresBackupMeteringState.record(timeline.id, values)

    postgres_resource.decr_reconcile_backup_metering

    Clog.emit("postgres backup metering swept", {backup_metering: {
      resource_ubid: postgres_resource.ubid,
      timeline_ubid: timeline.ubid,
      wal_bytes: total,
      wal_objects:,
      wal_days: days.size,
      wal_pages:,
      backup_bytes:,
      backup_objects:,
      backup_pages: walk_pages,
    }})

    pop "swept"
  rescue => ex
    swallow_blob_storage_error(ex)
  end

  private

  # nil when this resource holds no bucket of its own: read replicas and
  # un-promoted PITR restores resolve to their source's timeline, and would
  # otherwise be counted twice. Metal is excluded by policy, not capability.
  def timeline
    return @timeline if defined?(@timeline)

    server = postgres_resource.representative_server
    location = postgres_resource.location
    @timeline = server.timeline if server&.primary? && (location.aws? || location.gcp?)
  end

  def state
    return @state if defined?(@state)

    @state = PostgresBackupMeteringState[timeline.id]
  end

  # The continuation token supersedes start_after on every provider.
  def list_page(prefix, cursor, token)
    timeline.list_objects_page(prefix, start_after: (cursor if token.nil?), token:)
  end

  # Not via PostgresTimeline#backups, which swallows the same recoverable errors
  # and returns [], so a failed listing would land as a zero.
  def sentinels
    @sentinels ||= begin
      found = []
      token = nil
      loop do
        objects, token = timeline.list_objects_page(BACKUP_PREFIX, delimiter: "/", token:)
        found.concat(objects.select { it.key.end_with?(SENTINEL_SUFFIX) })
        break unless token
      end
      found
    end
  end

  def backup_name(key)
    rest = key.delete_prefix(BACKUP_PREFIX)
    rest.end_with?(SENTINEL_SUFFIX) ? rest.delete_suffix(SENTINEL_SUFFIX) : rest.split("/").first
  end

  def backup_walk_due?
    walked_at = state&.backup_walked_at
    return true if walked_at.nil? || walked_at < Time.now - BACKUP_WALK_INTERVAL

    started = timeline.latest_backup_started_at
    # Truncated: the frame carries whole seconds, latest_backup_started_at does not.
    return false if started.nil? || started.to_i == state.backup_started_seen&.to_i

    # latest_backup_started_at is set when the backup is issued, not when it
    # finishes, and wal-g writes the sentinel last.
    sentinels.any? { it.last_modified >= started }
  end

  # Keys sort chronologically, so the first WAL segment is the oldest survivor.
  # A .history file sorts before its own timeline's segments, so it is skipped.
  def wal_expiry_boundary
    probed_at = state&.boundary_probed_at
    return [state.boundary_day, probed_at] if probed_at && probed_at > Time.now - BOUNDARY_PROBE_INTERVAL

    objects, = timeline.list_objects_page(WAL_PREFIX)
    oldest = objects.find { PostgresTimeline::WAL_SEGMENT_RE.match?(it.key.delete_prefix(WAL_PREFIX).split(".").first) }
    [oldest&.last_modified&.utc&.to_date, Time.now]
  end

  # The boundary day is kept whole though partly expired, since dropping it
  # would report nothing for a timeline younger than the retention window.
  # Accepted over-report, bounded by one day of WAL.
  def expire_day_buckets(days, boundary_day)
    days = days.select { |day, _| day >= boundary_day.to_s } if boundary_day
    return days if days.size <= MAX_DAY_BUCKETS

    Clog.emit("postgres backup metering ledger over cap", {backup_metering: {
      resource_ubid: postgres_resource.ubid,
      timeline_ubid: timeline.ubid,
      days: days.size,
      boundary_day:,
    }})
    days.sort.last(MAX_DAY_BUCKETS).to_h
  end

  def abandon_walk?(prefix, pages)
    return false if pages <= MAX_WALK_PAGES

    Clog.emit("postgres backup metering walk abandoned", {backup_metering: {
      resource_ubid: postgres_resource.ubid,
      timeline_ubid: timeline.ubid,
      prefix:,
      pages:,
    }})
    true
  end

  # Transient or already-destroyed state, not a bug. Keep the measured values:
  # a zero would read as "this resource stores nothing".
  def swallow_blob_storage_error(ex)
    raise unless PostgresTimeline.recoverable_blob_storage_error?(ex)

    Clog.emit("postgres backup metering blob storage error", {
      backup_metering: {resource_ubid: postgres_resource.ubid},
    }.merge(Util.exception_to_hash(ex)))
    back_off "blob storage unavailable"
  end

  # Without moving swept_at the nexus buds again on its next pass, so an
  # unreachable bucket would be re-listed every 30s indefinitely.
  def back_off(message)
    PostgresBackupMeteringState.record(timeline.id, {swept_at: Time.now})
    postgres_resource.decr_reconcile_backup_metering
    pop message
  end
end
