# frozen_string_literal: true

class Clover
  def format_time_diff(start_time, end_time)
    diff = (end_time - start_time).to_i
    h, diff = diff.divmod(3600)
    m, s = diff.divmod(60)

    result = []
    result << "#{h}h" if h > 0
    result << "#{m}m" if m > 0
    result << "#{s}s" if s > 0
    result.empty? ? "0s" : result.join(" ")
  end
end
