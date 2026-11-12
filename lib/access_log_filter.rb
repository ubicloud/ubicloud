# frozen_string_literal: true

class AccessLogFilter
  QUIET_REQUEST = %r{"(?:POST /webhook/github[ ?]|[A-Z]+ /runtime/github/cache)[^"]*" [23]\d\d }

  def initialize(io)
    @io = io
  end

  def write(line)
    @io.write(line) unless QUIET_REQUEST.match?(line)
  end
end
