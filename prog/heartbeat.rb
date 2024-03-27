# frozen_string_literal: true

require "excon"

class Prog::Heartbeat < Prog::Base
  CONNECTED_APPLICATION_QUERY = <<SQL
SELECT
  (regexp_matches(application_name, '/(puma|monitor|respirate)$'))[1]
FROM
  (SELECT DISTINCT application_name FROM pg_stat_activity) AS psa
ORDER BY 1
SQL

  EXPECTED = %w[monitor puma respirate].freeze

  def fetch_connected
    DB[CONNECTED_APPLICATION_QUERY].flat_map(&:values).freeze
  end

  label def wait
    if (connected = fetch_connected) != EXPECTED
      Clog.emit("some expected connected clover services are missing") {
        {heartbeat_missing: {difference: EXPECTED.difference(connected)}}
      }
      nap 10
    end

    Excon.get(Config.heartbeat_url, read_timeout: 2, write_timeout: 2, connect_timeout: 2)
    nap 10
  rescue Excon::Error::Timeout => e
    Clog.emit("heartbeat request timed out") { {exception: {message: e.message}} }
    nap 10
  end
end
