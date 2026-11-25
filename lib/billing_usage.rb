# frozen_string_literal: true

class BillingUsage
  DAY = 24 * 60 * 60

  def self.month_range(now)
    month_start = Time.utc(now.year, now.month)
    month_end_date = Date.new(now.year, now.month, 1) >> 1
    [month_start, Time.utc(month_end_date.year, month_end_date.month)]
  end

  def self.amount_billed_scale(now)
    month_start, month_end = month_range(now)
    elapsed = now - month_start
    return if elapsed < 7 * DAY
    (month_end - month_start).fdiv(elapsed)
  end
end
