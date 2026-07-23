# frozen_string_literal: true

# :nocov:
require "bundler/setup" if File.directory?(File.expand_path("../../host", __dir__))
# :nocov:
require "open3"
require "shellwords"
require "openssl"
require_relative "command"

class CommandFail < RuntimeError
  attr_reader :stdout, :stderr

  def initialize(message, stdout, stderr)
    super(message)
    @stdout = stdout
    @stderr = stderr
  end

  def to_s
    [super, "\n---STDOUT---", @stdout, "\n---STDERR---", @stderr].join("\n")
  end
end

# rubocop:disable Lint/InheritException
class FsyncFail < Exception
end
# rubocop:enable Lint/InheritException

PotentialInsecurity = Command::PotentialInsecurity

# Safely build a shell command string from a template containing
# :placeholder tokens, substituting each with the corresponding keyword
# argument, shell-escaped. See Command.build for details.
def cmd(command, **kw)
  Command.build(command, "cmd", __FILE__, true, **kw)
end

# :nocov:
if defined?(RSpec)
  class MissingMock < StandardError
  end

  # :nocov:
  class Object
    private

    def _run_command(*command, _skip_command_checking: false, **kw)
      unless _skip_command_checking
        raise MissingMock, "_run_command not mocked. You must add a spec that checks for the expected command. Command: #{command.inspect}"
      end

      super(*command, **kw)
    end
  end
end

module Kernel
  def _run_command(*command, stdin: "", expect: [0])
    stdout, stderr, status = Open3.capture3(*command, stdin_data: stdin)
    fail CommandFail.new("command failed: " + command.join(" "), stdout, stderr) unless expect.include?(status.exitstatus)

    stdout
  end
end

def r(*command, stdin: nil, expect: nil, **kw)
  unless kw.empty?
    raise ArgumentError, "placeholder keywords require a single shell command string" unless command.length == 1 && command[0].is_a?(String)
    command = [cmd(command[0], **kw)]
  end

  if command.length == 1 && command[0].is_a?(String) && !command[0].frozen?
    raise PotentialInsecurity, "Interpolated string passed to r at #{caller(1, 1).first}\nReplace interpolation with :placeholders passed directly to r, or use separate positional arguments instead."
  end

  kw = {stdin: stdin, expect: expect}
  kw.compact!
  _run_command(*command, **kw)
end

def rm_if_exists(path)
  FileUtils.rm_r(path)
rescue Errno::ENOENT
  # ignore if path doesn't exist, otherwise raise error
  nil
end

def fsync_or_fail(f)
  # Throw a custom exception type inheriting directly from Exception,
  # unlikely to be accidentally rescued as to better halt the program
  # in event of fsync errors.
  #
  # The ultimate goal of fsync errors is to page.  Halting progress is
  # one roundabout but easy way of doing that.
  #
  # Note that IO::fsync raises an exception on error based on its source
  # in the docs: https://ruby-doc.org/core-2.4.2/IO.html#method-i-fsync
  f.fsync
rescue SystemCallError => e
  raise FsyncFail.new(e.message)
end

def sync_parent_dir(f)
  parent_dir = Pathname.new(f).parent.to_s
  File.open(parent_dir) {
    fsync_or_fail(_1)
  }
end

def safe_write_to_file(filename, content = nil)
  raise ArgumentError, "must provide either content or block" if content.nil? ^ block_given?

  temp_filename = filename + ".tmp"
  lock_filename = "/tmp/#{OpenSSL::Digest::SHA256.hexdigest(temp_filename)}.lock"
  File.open(lock_filename, File::RDWR | File::CREAT) do |lock_file|
    lock_file.flock(File::LOCK_EX)
    if block_given?
      File.open(temp_filename, "w") do |f|
        yield f
      end
    else
      File.write(temp_filename, content)
    end
    File.rename(temp_filename, filename)
  end
end

def curl_file(url, path)
  inner = cmd("curl -f -L3 :url | tee >(openssl dgst -sha256) > :path", url: url, path: path)
  r("bash -c :inner", inner: inner).split(" ").last
end

def validate_keys(context, required_keys, optional_keys, hash)
  all_keys = required_keys + optional_keys
  missing_keys = required_keys - hash.keys
  extra_keys = hash.keys - all_keys
  unless missing_keys.empty?
    raise ArgumentError, "Missing required keys in #{context}: #{missing_keys.join(", ")}"
  end

  unless extra_keys.empty?
    raise ArgumentError, "Unexpected keys in #{context}: #{extra_keys.join(", ")}"
  end
end
