# frozen_string_literal: true

require "bundler/setup"
require "open3"
require "shellwords"
require "digest"

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

def r(commandline, stdin: "")
  stdout, stderr, status = Open3.capture3(commandline, stdin_data: stdin)
  fail CommandFail.new("command failed: " + commandline, stdout, stderr) unless status.success?
  stdout
end

def rm_if_exists(path)
  FileUtils.rm_r(path)
rescue Errno::ENOENT
  # ignore if path doesn't exist, otherwise raise error
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
  raise ArgumentError, "must provide either content or block" if (content.nil? && !block_given?) || (!content.nil? && block_given?)
  temp_filename = filename + ".tmp"
  lock_filename = "/tmp/#{Digest::SHA256.hexdigest(temp_filename)}.lock"
  File.open(lock_filename, File::RDWR | File::CREAT) do |lock_file|
    lock_file.flock(File::LOCK_EX)
    if block_given?
      File.open(temp_filename, File::RDWR | File::CREAT) do |f|
        yield f
      end
    else
      File.write(temp_filename, content)
    end
    File.rename(temp_filename, filename)
  end
end
