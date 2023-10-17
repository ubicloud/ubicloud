# frozen_string_literal: true

class Prog::LearnStorage < Prog::Base
  subject_is :sshable

  ParseDf = Struct.new(:size_gib, :avail_gib) do
    def self.parse(s)
      m = /\A\s*1B-blocks\s+Avail\n(\d+)\s+(\d+)\s*\n\z/.match(s)
      fail "BUG: unexpected output from df" unless m
      new(*m.captures.map { Integer(_1) / 1073741824 })
    end
  end

  label def start
    q_storage_root = "/var".shellescape.freeze
    parsed = ParseDf.parse(sshable.cmd("df -B1 --output=size,avail #{q_storage_root}"))

    # reserve 5G for future host related stuff
    available_storage_gib = [0, parsed.avail_gib - 5].max
    pop total_storage_gib: parsed.size_gib, available_storage_gib: available_storage_gib
  end
end
