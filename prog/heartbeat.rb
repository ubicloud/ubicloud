# frozen_string_literal: true

require "excon"

class Prog::Heartbeat < Prog::Base
  label def wait
    DB["SELECT 1"].first
    Excon.get(Config.heartbeat_url, read_timeout: 2, write_timeout: 2, connect_timeout: 2)
    nap 10
  rescue Excon::Error::Timeout => e
    Clog.emit("heartbeat request timed out") { {exception: {message: e.message}} }
    nap 10
  end
end
