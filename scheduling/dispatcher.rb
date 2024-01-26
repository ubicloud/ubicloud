# frozen_string_literal: true

class Scheduling::Dispatcher
  attr_reader :notifiers

  def initialize
    @apoptosis_timeout = Strand::LEASE_EXPIRATION - 29
    @notifiers = []
  end

  def scan
    idle_connections = Config.db_pool - @notifiers.count - 1
    if idle_connections < 1
      Clog.emit("Not enough database connections.") do
        {pool: {db_pool: Config.db_pool, active_threads: @notifiers.count}}
      end
      return []
    end

    Strand.dataset.where(
      Sequel.lit("(lease IS NULL OR lease < now()) AND schedule < now() AND exitval IS NULL")
    ).order_by(:schedule).limit(idle_connections)
  end

  def start_strand(strand)
    strand_ubid = strand.ubid.freeze
    apoptosis_r, apoptosis_w = IO.pipe
    notify_r, notify_w = IO.pipe

    Thread.new do
      ready, _, _ = IO.select([apoptosis_r], nil, nil, @apoptosis_timeout)

      if ready.nil?
        # Timed out, dump threads and exit
        ThreadPrinter.run
        Kernel.exit!

        # rubocop:disable Lint/UnreachableCode
        # Reachable in test only.
        next
        # rubocop:enable Lint/UnreachableCode
      end

      ready.first.close
    end.tap { _1.name = "apoptosis:" + strand_ubid }

    Thread.new do
      strand.run Strand::LEASE_EXPIRATION / 4
    rescue => ex
      Clog.emit("exception terminates thread") { Util.exception_to_hash(ex) }

      loop do
        ex = ex.cause
        break unless ex
        Clog.emit("nested exception") { Util.exception_to_hash(ex) }
      end
    ensure
      # Adequate to unblock IO.select.
      apoptosis_w.close
      notify_w.close
    end.tap { _1.name = strand_ubid }

    notify_r
  end

  def start_cohort
    scan.each do |strand|
      @notifiers << start_strand(strand)
    end
  end

  def wait_cohort
    return 0 if @notifiers.empty?
    ready, _, _ = IO.select(@notifiers)
    ready.each(&:close)
    @notifiers.delete_if { ready.include?(_1) }
    ready.count
  end
end
