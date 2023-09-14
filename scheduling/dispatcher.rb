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
      puts "Not enough database connections. Waiting active connections to finish their work. db_pool:#{Config.db_pool} active_threads:#{@notifiers.count}"
      return []
    end

    Strand.dataset.where(
      Sequel.lit("(lease IS NULL OR lease < now()) AND schedule < now()")
    ).order_by(:schedule).limit(idle_connections)
  end

  def start_strand(strand)
    strand_id = strand.id.freeze

    r, w = IO.pipe

    Thread.new do
      ready, _, _ = IO.select([r], nil, nil, @apoptosis_timeout)

      if ready.nil?
        # Timed out, dump threads and exit
        ThreadPrinter.run
        Kernel.exit!

        # rubocop:disable Lint/UnreachableCode
        # Reachable in test only.
        next
        # rubocop:enable Lint/UnreachableCode
      end
    end

    Thread.new do
      strand.run Strand::LEASE_EXPIRATION / 4
    ensure
      # Adequate to unblock IO.select.
      w.close
    end.tap { _1.name = strand_id }

    r
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
