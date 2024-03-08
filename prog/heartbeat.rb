# frozen_string_literal: true

require "excon"

class Prog::Heartbeat < Prog::Base
  CONNECTED_APPLICATION_QUERY = <<SQL
SELECT count(DISTINCT application_name)
FROM pg_stat_activity
WHERE application_name ~ '^(bin/respirate|bin/monitor|.*/puma)$'
SQL

  label def wait
    nap 10 unless DB.get(CONNECTED_APPLICATION_QUERY) == 3
    Excon.get(Config.heartbeat_url, read_timeout: 2, write_timeout: 2, connect_timeout: 2)
    nap 10
  rescue Excon::Error::Timeout => e
    Clog.emit("heartbeat request timed out") { {exception: {message: e.message}} }
    nap 10
  end
end
