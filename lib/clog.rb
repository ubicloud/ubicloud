# frozen_string_literal: true

require "json"

class Clog
  # rubocop:disable Lint/InheritException
  #
  # Make "Bug" hard to rescue via inheritance from Exception: it is
  # used in broken-invariant cases and should have the best chance of
  # stopping computation of its thread.
  class Bug < Exception
    def initialize(msg, meta)
      @meta = meta
      super msg
    end
  end
  # rubocop:enable Lint/InheritException

  def self.info(line, meta = nil)
    emit(line, meta, boilerplate("INFO"))
  end

  def self.warn(line, meta = nil)
    emit(line, meta, boilerplate("WARN"))
  end

  def self.bug(line, meta = nil)
    emit(line, meta, boilerplate("FATAL"))
    fail Bug.new(line, meta)
  end

  def self.boilerplate(level = "INFO", now = Time.now)
    {app: "clover", timestamp: (now.tv_sec * 1000 + now.tv_usec / 1000), level: level}
  end

  def self.emit(line, meta, dat)
    dat[:line] = line
    dat[:meta] = meta if meta

    # Emit dat to stdout, up to PIPE_BUF in length.
    #
    # PIPE_BUF is a POSIX value set a C macro, often set to 4096 on
    # Linux systems.  Generally, systems do not fragment system calls
    # across the pipe that are equal to or less than this value.  This
    # datagram-like atomicity can be used to know something about how
    # race conditions writing to, say, $stdout will be framed by
    # matching reads by another process.
    #
    # To expose this constant to ruby, we'd need a C extension with
    # code like:
    #
    #     rb_define_const(mSomemodule, "PIPE_BUF", UINT2NUM(PIPE_BUF));
    #
    out = JSON.generate(dat)

    # Add a newline to make debugging raw output a bit nicer.
    $stdout.write(out[0..4094] + "\n")
  end
end
