# frozen_string_literal: true

require_relative "../../model"
require "aws-sdk-s3"

class PostgresTimeline < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :parent, class: self
  one_to_one :leader, class: :PostgresServer, key: :timeline_id, conditions: {timeline_access: "push"}, is_used: true
  many_to_one :location, read_only: true

  plugin ResourceMethods, encrypted_columns: :secret_key
  plugin ProviderDispatcher, __FILE__
  plugin SemaphoreMethods, :destroy

  BACKUP_BUCKET_EXPIRATION_DAYS = 8

  def bucket_name
    ubid
  end

  def need_backup?
    return false if blob_storage.nil?
    return false if leader.nil?

    status = leader.vm.sshable.cmd("common/bin/daemonizer --check take_postgres_backup")
    return true if ["Failed", "NotStarted"].include?(status)
    return true if status == "Succeeded" && (latest_backup_started_at.nil? || latest_backup_started_at < Time.now - 60 * 60 * backup_period_hours)

    false
  end

  # End LSN of the last archived WAL segment on the latest archived
  # timeline, formatted as the `X/Y` hex pair postgres uses for
  # recovery_target_lsn. Caps how far a PITR restore against an orphaned
  # timeline can reach.
  #
  # wal-g segment names are `<timeline 8hex><log 8hex><seg 8hex>`. End LSN
  # is exclusive; postgres replays bytes < target.
  #
  # Picks tail within the highest archived timeline, not the global max:
  # async replica that promotes after lag forks a new timeline at an LSN
  # behind the old leader's tail, so the abandoned old timeline can still
  # have archived segments past where the new timeline ever reached.
  # recovery_target_timeline=latest follows the new timeline, where those
  # bytes don't exist.
  WAL_FILE_RE = /\A([0-9A-F]{8})([0-9A-F]{8})([0-9A-F]{8})\z/
  WAL_SEGMENT_BYTES = 16 * 1024 * 1024 # postgres default, not overridden in this codebase

  # To allow overriding in specs
  def self.latest_archived_wal_lsn(timeline)
    timeline.latest_archived_wal_lsn
  end

  def latest_archived_wal_lsn
    return nil if blob_storage.nil?
    segments = list_objects("wal_005/").filter_map { |o|
      m = WAL_FILE_RE.match(o.key.delete_prefix("wal_005/").split(".").first)
      [Integer(m[1], 16), Integer(m[2], 16), Integer(m[3], 16)] if m
    }
    return nil if segments.empty?
    latest_tli = segments.map(&:first).max
    _, log, seg = segments.select { |t, _, _| t == latest_tli }.max_by { |_, l, s| [l, s] }
    end_byte = (seg + 1) * WAL_SEGMENT_BYTES
    format("%X/%X", log + (end_byte >> 32), end_byte & 0xFFFFFFFF)
  end

  def backups
    return [] if blob_storage.nil?

    begin
      list_objects("basebackups_005/", delimiter: "/")
        .select { it.key.end_with?("backup_stop_sentinel.json") }
    rescue => ex
      recoverable_errors = ["The AWS Access Key Id you provided does not exist in our records.", "The specified bucket does not exist", "AccessDenied", "No route to host", "Connection refused"]
      Clog.emit("Backup fetch exception", Util.exception_to_hash(ex))
      return [] if recoverable_errors.any? { ex.message.include?(it) }

      raise
    end
  end

  def latest_backup_label_before_target(target:)
    backup = backups.sort_by(&:last_modified).reverse.find { it.last_modified < target }
    fail "BUG: no backup found" unless backup

    backup.key.delete_prefix("basebackups_005/").delete_suffix("_backup_stop_sentinel.json")
  end

  # To allow overriding in specs
  def self.earliest_restore_time(timeline)
    timeline.earliest_restore_time
  end

  def earliest_restore_time
    # Check if we have cached earliest backup time, if not, calculate it.
    # The cached time is valid if its within BACKUP_BUCKET_EXPIRATION_DAYS.
    time_limit = Time.now - BACKUP_BUCKET_EXPIRATION_DAYS * 24 * 60 * 60

    if cached_earliest_backup_at.nil? || cached_earliest_backup_at <= time_limit
      earliest_backup = backups
        .select { |b| b.last_modified > time_limit }
        .map(&:last_modified).min

      update(cached_earliest_backup_at: earliest_backup)
    end

    if cached_earliest_backup_at
      cached_earliest_backup_at + 5 * 60
    end
  end

  def latest_restore_time
    Time.now
  end

  def aws?
    location.aws?
  end

  def provider_dispatcher_group_name
    location.provider_dispatcher_group_name
  end

  S3BlobStorage = Struct.new(:url)

  def blob_storage_endpoint
    @blob_storage_endpoint ||= blob_storage.url || blob_storage.ip4_urls.sample
  end

  def blob_storage_policy
    {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::#{ubid}*"]}]}
  end
end

# Table: postgres_timeline
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  created_at                | timestamp with time zone | NOT NULL DEFAULT now()
#  parent_id                 | uuid                     |
#  access_key                | text                     |
#  secret_key                | text                     |
#  latest_backup_started_at  | timestamp with time zone |
#  location_id               | uuid                     |
#  cached_earliest_backup_at | timestamp with time zone |
#  backup_period_hours       | smallint                 | NOT NULL DEFAULT 24
# Indexes:
#  postgres_timeline_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_timeline_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_server | postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
