# frozen_string_literal: true

require "rbconfig"

ArchClass = Struct.new(:sym) {
  def self.from_system
    new case RbConfig::CONFIG.fetch("target_cpu").downcase
    when /arm64|aarch64/
      "arm64"
    when /amd64|x86_64|x64/
      "x64"
    else
      fail "BUG: could not detect architecture"
    end.intern
  end

  def arm64?
    sym == :arm64
  end

  def x64?
    sym == :x64
  end

  def render(x64: sym, arm64: sym)
    if x64?
      x64
    elsif arm64?
      arm64
    else
      fail "BUG: could not detect architecture"
    end.to_s
  end
}
