# frozen_string_literal: true

require_relative "../../model"

# How many embers one address has created in the current window.
#
# Anonymous creation has nothing to authenticate, so the address is all there
# is to limit on. The count lives in the database rather than in a process, so
# that the limit is the same one whichever web process answers.
class PostgresEmberRateLimit < Sequel::Model
  unrestrict_primary_key

  WINDOW = 24 * 60 * 60

  # Count one attempt against an address and return the new total.
  #
  # A single statement, so two simultaneous requests from the same address
  # cannot both read a stale count. The window is reset in the same statement
  # when the old one has run out.
  def self.record(ip, window: WINDOW)
    cutoff = Time.now - window
    row = DB[<<~SQL, ip.to_s, cutoff, cutoff].first
      INSERT INTO postgres_ember_rate_limit (ip, window_start, count) VALUES (?, now(), 1)
      ON CONFLICT (ip) DO UPDATE SET
        count = CASE WHEN postgres_ember_rate_limit.window_start < ? THEN 1 ELSE postgres_ember_rate_limit.count + 1 END,
        window_start = CASE WHEN postgres_ember_rate_limit.window_start < ? THEN now() ELSE postgres_ember_rate_limit.window_start END
      RETURNING count
    SQL
    row[:count]
  end

  # Give an attempt back, so that a create that never happened does not count
  # against the address.
  def self.refund(ip)
    where(ip: ip.to_s).where { count > 0 }.update(count: Sequel[:count] - 1)
  end
end

# Table: postgres_ember_rate_limit
# Columns:
#  ip           | inet                     | PRIMARY KEY
#  window_start | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  count        | integer                  | NOT NULL DEFAULT 0
# Indexes:
#  postgres_ember_rate_limit_pkey | PRIMARY KEY btree (ip)
