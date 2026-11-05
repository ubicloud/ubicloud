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
  plugin SemaphoreMethods, :destroy, :take_backup_for_converge, :refresh_blob_storage_policy

  BACKUP_BUCKET_EXPIRATION_DAYS = 8
  DOWNLOAD_CREDENTIALS_DURATION_SECONDS = 60 * 60 * 36

  def bucket_name
    ubid
  end

  def walg_config_env_contents(server)
    return "" unless walg_optimized_config_enabled?
    return "" unless (params = walg_config_params(server))

    direct_io = walg_direct_io_enabled?
    direct_io_drive_count = server.storage_device_paths.count if direct_io
    WalgConfig.config_env_contents(**params, direct_io:, direct_io_drive_count:)
  end

  def walg_optimized_config_enabled?
    !leader.nil? && !leader.resource.project.get_ff_postgres_walg_optimized_config_disabled
  end

  def walg_direct_io_enabled?
    !leader.resource.project.get_ff_postgres_walg_direct_io_disabled
  end

  def need_backup?
    return false if blob_storage.nil?
    return false if leader.nil?
    return true if take_backup_for_converge_set?

    if backup_window_start_at.nil?
      return false if latest_backup_started_at && latest_backup_started_at > Time.now - 60 * 60 * backup_period_hours
    elsif backup_slot_offset_hours < backup_window_hours
      return false if latest_backup_started_at && latest_backup_started_at >= backup_slot_open_at
    elsif !backup_overdue?
      Clog.emit("Backup skipped: outside backup window", self)
      return false
    end

    leader.vm.sshable.d_check("take_postgres_backup") != "InProgress"
  end

  # Backup slots are aligned to UTC epoch hours: one opens every
  # backup_period_hours hours, starting at backup_window_start_at.
  def backup_window_hours
    (backup_period_hours / 2).clamp(1, 4)
  end

  def backup_slot_offset_hours
    ((Time.now.to_i / 3600) - backup_window_start_at) % backup_period_hours
  end

  def backup_slot_open_at
    Time.at((Time.now.to_i / 3600 - backup_slot_offset_hours) * 3600)
  end

  # Time the next slot opens, or nil if no backup window is configured.
  def next_backup_slot_at
    backup_slot_open_at + 60 * 60 * backup_period_hours if backup_window_start_at
  end

  # A backup is overdue if none was ever started, or the last one started
  # more than a day later than the period allows.
  def backup_overdue?
    latest_backup_started_at.nil? || latest_backup_started_at < Time.now - 60 * 60 * (backup_period_hours + 24)
  end

  def backup_schedule
    values.slice(:backup_window_start_at, :backup_retention_days, :backup_period_hours)
  end

  def validate
    super
    validates_includes(0..23, :backup_window_start_at, allow_nil: true, message: "must be between 0 and 23")
    validates_includes(1..168, :backup_period_hours, allow_nil: true, message: "must be between 1 and 168")
    validates_includes(1..35, :backup_retention_days, allow_nil: true, message: "must be between 1 and 35")
  end

  # wal-g segment names are `<timeline 8hex><log 8hex><seg 8hex>`; .history
  # & other objects don't match
  WAL_SEGMENT_RE = /\A[0-9A-F]{24}\z/

  # To allow overriding in specs
  def self.any_archived_wal?(timeline)
    timeline.any_archived_wal?
  end

  # Whether any WAL segment has been archived. Gates unarchive E2E until
  # post-backup writes land in the archive, not the live tail segment.
  def any_archived_wal?
    return false if blob_storage.nil?
    list_objects("wal_005/").any? { WAL_SEGMENT_RE.match?(it.key.delete_prefix("wal_005/").split(".").first) }
  end

  def backups
    return @backups if @backups
    return @backups = [] if blob_storage.nil?

    @backups = list_objects("basebackups_005/", delimiter: "/").select { it.key.end_with?("backup_stop_sentinel.json") }
  rescue => ex
    recoverable_errors = ["Access Key Id you provided does not exist in our records.", "The specified bucket does not exist", "AccessDenied", "No route to host", "Connection refused"]
    Clog.emit("Backup fetch exception", Util.exception_to_hash(ex))
    raise unless recoverable_errors.any? { ex.message.include?(it) }

    @backups = []
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

  # Least-privilege, read-only policy handed to customers for downloading their own
  # backups. Passed as an inline STS session policy when minting temporary credentials
  # (see #create_download_credentials) rather than attached to a persistent IAM/canned
  # policy object, since no standing credential is created for this feature.
  def download_blob_storage_policy
    {Version: "2012-10-17", Statement: [
      {Effect: "Allow", Action: ["s3:ListBucket", "s3:GetBucketLocation"], Resource: ["arn:aws:s3:::#{ubid}"]},
      {Effect: "Allow", Action: ["s3:GetObject", "s3:GetObjectVersion"], Resource: ["arn:aws:s3:::#{ubid}/basebackups_005/*", "arn:aws:s3:::#{ubid}/wal_005/*"]},
    ]}
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
#  latest_backup_size_in_gib | bigint                   |
#  backup_window_start_at    | smallint                 |
#  backup_retention_days     | smallint                 | NOT NULL DEFAULT 7
# Indexes:
#  postgres_timeline_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  valid_backup_period_hours    | (backup_period_hours >= 1 AND backup_period_hours <= 168)
#  valid_backup_retention_days  | (backup_retention_days >= 1 AND backup_retention_days <= 35)
#  valid_backup_window_start_at | (backup_window_start_at >= 0 AND backup_window_start_at <= 23)
# Foreign key constraints:
#  postgres_timeline_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_server | postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
