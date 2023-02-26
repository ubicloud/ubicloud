# frozen_string_literal: true

class Scheduling::Dispatcher
  attr_reader :threads

  def initialize
    @threads = []
  end

  def scan
    Strand.dataset.where(
      Sequel.lit("(lease IS NULL OR lease < now()) AND schedule < now()")
    ).order_by(:schedule).limit(Config.db_pool - @threads.count - 1)
  end

  def start_cohort
    scan.each do |strand|
      @threads << Thread.new do
        strand.run
      end.tap { _1.name = strand.id }
    end
  end

  def wait_cohort
    @threads.filter! do |th|
      th.alive?
    end
  end
end
