# frozen_string_literal: true

class Scheduling::Dispatcher
  attr_reader :threads

  def initialize
    @dump_timeout = 1
    @apoptosis_timeout = Strand::LEASE_EXPIRATION - @dump_timeout - 29
    @threads = []
  end

  def scan
    idle_connections = Config.db_pool - @threads.count - 1
    if idle_connections < 1
      puts "Not enough database connections. Waiting active connections to finish their work. db_pool:#{Config.db_pool} active_threads:#{@threads.count}"
      return []
    end

    Strand.dataset.where(
      Sequel.lit("(lease IS NULL OR lease < now()) AND schedule < now()")
    ).order_by(:schedule).limit(idle_connections)
  end

  def self.print_thread_dump
    Thread.list.each do |thread|
      puts "Thread: #{thread.inspect}"
      puts thread.backtrace&.join("\n")
    end
  end

  def start_strand(strand)
    strand_id = strand.id.freeze

    r, w = IO.pipe

    Thread.new do
      ready, _, _ = IO.select([r], nil, nil, @apoptosis_timeout)

      if ready.nil?
        # Timed out, dump threads and exit
        self.class.print_thread_dump
        Kernel.exit!

        # rubocop:disable Lint/UnreachableCode
        # Reachable in test only.
        next
        # rubocop:enable Lint/UnreachableCode
      end

      ready.first.close
    end

    Thread.new do
      strand.run Strand::LEASE_EXPIRATION / 4
    ensure
      # Adequate to unblock IO.select.
      w.close
    end.tap { _1.name = strand_id }
  end

  def start_cohort
    scan.each do |strand|
      @threads << start_strand(strand)
    end
  end

  def wait_cohort
    @threads.filter! do |th|
      th.alive?
    end
  end
end
