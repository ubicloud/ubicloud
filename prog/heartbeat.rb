# frozen_string_literal: true

require "excon"

class Prog::Heartbeat < Prog::Base
  label def wait
    DB["SELECT 1"].first
    Excon.get(Config.heartbeat_url)
    nap 10
  end
end
