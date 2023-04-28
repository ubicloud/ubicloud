# frozen_string_literal: true

require "bundler/setup"
require "open3"
require "shellwords"

class CommandFail < RuntimeError
  attr_reader :stdout, :stderr

  def initialize(message, stdout, stderr)
    super message
    @stdout = stdout
    @stderr = stderr
  end

  def to_s
    [super, "\n---STDOUT---", @stdout, "\n---STDERR---", @stderr].join("\n")
  end
end

def r(commandline)
  stdout, stderr, status = Open3.capture3(commandline)
  fail CommandFail.new("command failed: " + commandline, stdout, stderr) unless status.success?
  stdout
end
