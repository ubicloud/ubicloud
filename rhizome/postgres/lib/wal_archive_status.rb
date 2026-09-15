# frozen_string_literal: true

require_relative "../../common/lib/util"

class WalArchiveStatus
  WAL_SEGMENT_SIZE = 16 * 1024 * 1024
  DONE_MARKER_RE = /\A[0-9A-F]{24}\.done\z/

  def initialize(version, logger, max_segments: 128)
    @path = "/dat/#{version}/data/pg_wal/archive_status"
    @logger = logger
    @max_segments = max_segments
  end

  def wal_end_segment
    lsn = r("sudo -u postgres psql -t -A -c 'SELECT greatest(pg_catalog.pg_last_wal_receive_lsn(), pg_catalog.pg_last_wal_replay_lsn())'").strip
    log_id, offset = lsn.split("/").map { |part| part.to_i(16) }
    format("%08X%08X", log_id, offset / WAL_SEGMENT_SIZE)
  end

  def complete_segments
    cutoff = wal_end_segment
    Dir.children(@path)
      .filter_map { |name| name.delete_suffix(".done") if DONE_MARKER_RE.match?(name) }
      .select { |segment| segment[8..] < cutoff }
      .max(@max_segments)
  end

  def mark_received_segments_ready
    marked = complete_segments.count do |segment|
      File.rename(File.join(@path, "#{segment}.done"), File.join(@path, "#{segment}.ready"))
      true
    rescue Errno::ENOENT
      false
    end

    @logger.info("#{marked} received segments marked ready for archiving")
  end
end
