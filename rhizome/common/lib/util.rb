# frozen_string_literal: true

# :nocov:
require "bundler/setup" if File.directory?(File.expand_path("../../host", __dir__))
# :nocov:
require "open3"
require "shellwords"
require "openssl"

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

class MissingMock < StandardError
end

class PotentialInsecurity < StandardError
end

# Safely build a shell command string from a template containing
# :placeholder tokens, substituting each with the corresponding keyword
# argument, shell-escaped. A keyword whose name starts with "shelljoin_"
# is expected to hold an Array, joined into multiple shell-escaped words
# instead of a single escaped word. Placeholders are not allowed inside
# quotes, since shell-escaping a value for unquoted context and then
# wrapping it in quotes anyway produces incorrect (and unsafe) results.
def cmd(command, **kw)
  raise TypeError, "invalid type passed to cmd: #{command.inspect}" unless command.is_a?(String)
  return command if kw.empty?
  raise PotentialInsecurity, "Interpolated string passed to cmd at #{caller(1, 1).first}\nReplace interpolation with :placeholders and provide values for placeholders in keyword arguments." unless command.frozen?

  result = +""
  mode = :unquoted
  base_re = Regexp.union(kw.keys.map(&:to_s))
  unquoted_re, single_re, double_re = nil
  until command.empty?
    re = case mode
    when :unquoted
      unquoted_re ||= /(\\.|['"]|#.*$)|:(#{base_re})\b/
    when :single
      single_re ||= /(')|:(#{base_re})\b/
    else # :double
      double_re ||= /(\\.|")|:(#{base_re})\b/
    end

    pre, _, command = command.partition(re)
    ch = $1
    q = $2

    if ch
      case mode
      when :unquoted
        case ch
        when "'"
          mode = :single
        when '"'
          mode = :double
        end
      when :single
        mode = :unquoted
      else # :double
        mode = :unquoted if ch == '"'
      end
      result << pre << ch
    elsif mode != :unquoted
      if q && !q.empty?
        raise PotentialInsecurity, "Placeholder '#{q}' inside #{mode} quote in command at #{caller(1, 1).first}\nFix command to move the placeholder outside quotes, because shell escaping does not work correctly inside quotes."
      end
    else
      result << pre
      if q && !q.empty?
        v = kw[q.to_sym]
        result << if q.start_with?("shelljoin_")
          v.shelljoin
        else
          v.to_s.shellescape
        end
      end
    end
  end

  unless mode == :unquoted
    raise PotentialInsecurity, "Unterminated #{mode} quote in command at #{caller(1, 1).first}\nFix command syntax."
  end

  result.freeze
end

def _run_command(*command, stdin: "", expect: [0], _skip_command_checking: false)
  if !_skip_command_checking && defined?(RSpec)
    raise MissingMock, "_run_command not mocked. You must add a spec that checks for the expected command. Command: #{command.inspect}"
  end

  stdout, stderr, status = Open3.capture3(*command, stdin_data: stdin)
  fail CommandFail.new("command failed: " + command.join(" "), stdout, stderr) unless expect.include?(status.exitstatus)

  stdout
end

def r(*command, **kw)
  if command.length == 1 && command[0].is_a?(String) && !command[0].frozen?
    raise PotentialInsecurity, "Interpolated string passed to r at #{caller(1, 1).first}\nReplace interpolation with cmd and :placeholders, or use separate positional arguments instead."
  end

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
  r(cmd("bash -c :inner", inner: inner)).split(" ").last
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
