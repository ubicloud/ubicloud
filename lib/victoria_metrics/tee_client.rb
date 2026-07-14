# frozen_string_literal: true

require "delegate"

class VictoriaMetrics::TeeClient < SimpleDelegator
  def initialize(primary:, secondaries:)
    super(primary)
    @secondaries = secondaries
  end

  def import_prometheus(scrape, extra_labels = {})
    result = super

    @secondaries.each do |secondary|
      secondary.import_prometheus(scrape, extra_labels)
    rescue => ex
      Clog.emit("VictoriaMetrics secondary write failed", Util.exception_to_hash(ex))
    end

    result
  end
end
