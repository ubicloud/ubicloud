# frozen_string_literal: true

require_relative "../../common/lib/util"

class WalArchiveBackfill
  WAL_SEGMENT_RE = /\A[0-9A-F]{24}\z/

  def initialize(version, logger, max_segments: 128)
    @pg_wal_path = "/dat/#{version}/data/pg_wal"
    @logger = logger
    @max_segments = max_segments
  end

  def current_timeline
    timelines = Dir.glob("#{@pg_wal_path}/*.history").map { |f| File.basename(f, ".history").to_i(16) }
    fail "no timeline history file in #{@pg_wal_path}" if timelines.empty?
    timelines.max
  end

  def candidates
    timeline = current_timeline
    Dir.children(@pg_wal_path)
      .select { |f| WAL_SEGMENT_RE.match?(f) && f[0, 8].to_i(16) < timeline }
      .max(@max_segments)
  end

  def run
    segments = candidates
    @logger.info("#{segments.count} old-timeline segments to check")
    uploaded = archived = recycled = 0

    segments.each do |segment|
      path = File.join(@pg_wal_path, segment)

      unless File.exist?(path)
        @logger.info("recycled meanwhile: #{segment}")
        recycled += 1
        next
      end

      output = r "sudo -u postgres env WALG_PREVENT_WAL_OVERWRITE=true WALG_UPLOAD_CONCURRENCY=1 wal-g wal-push :path --config /etc/postgresql/wal-g.env 2>&1", path: path
      if output.include?("already archived")
        @logger.info("already archived: #{segment}")
        archived += 1
      else
        @logger.info("uploaded: #{segment}")
        uploaded += 1
      end
    end

    @logger.info("done: #{uploaded} uploaded, #{archived} already archived, #{recycled} recycled meanwhile")
  end
end
