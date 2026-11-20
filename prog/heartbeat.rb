# frozen_string_literal: true

require "excon"

class Prog::Heartbeat < Prog::Base
  EXPECTED = %w[monitor respirate].freeze

  def fetch_connected
    DB[<<SQL].select_map(:psa)
SELECT
  (regexp_matches(application_name, '/(monitor|respirate)$'))[1]
FROM
  (SELECT DISTINCT application_name FROM pg_stat_activity) AS psa
ORDER BY 1
SQL
  end

  label def wait
    if (connected = fetch_connected) == EXPECTED
      begin
        Excon.get(Config.heartbeat_url, read_timeout: 2, write_timeout: 2, connect_timeout: 2)
      rescue Excon::Error::Timeout => e
        Clog.emit("heartbeat request timed out", {exception: {message: e.message}})
      end
    else
      Clog.emit("some expected connected clover services are missing", {heartbeat_missing: {difference: EXPECTED.difference(connected)}})
    end

    nap 10
  end
end
