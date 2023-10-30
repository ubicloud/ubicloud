# frozen_string_literal: true

require "rbconfig"

ArchClass = Struct.new(:sym) {
  def self.from_system
    sym = case RbConfig::CONFIG.fetch("target_cpu").downcase
    when /arm64|aarch64/
      "arm64"
    when /amd64|x86_64|x64/
      "x64"
    else
      fail "BUG: could not detect architecture"
    end.intern
    new sym
  end

  def arm64?
    sym == :arm64
  end

  def x64?
    sym == :x64
  end
}

Arch = ArchClass.from_system
