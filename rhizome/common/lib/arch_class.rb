# frozen_string_literal: true

require "rbconfig"

ArchClass = Struct.new(:sym) {
  def self.from_system
    new case RbConfig::CONFIG.fetch("target_cpu")
    when /arm64|aarch64/i
      :arm64
    when /amd64|x86_64|x64/i
      :x64
    else
      fail "BUG: could not detect architecture"
    end
  end

  def arm64?
    sym == :arm64
  end

  def x64?
    sym == :x64
  end

  def render(x64:, arm64:)
    {x64:, arm64:}.fetch(sym)
  end
}
