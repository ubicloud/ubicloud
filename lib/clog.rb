# frozen_string_literal: true

require "json"

class Clog
  @@mutex = Mutex.new

  def self.emit(message)
    out = if block_given?
      case v = yield
      when Hash
        v
      else
        {invalid_type: v.class.to_s}
      end
    else
      {}
    end

    return if Config.test?
    out[:message] = message
    out[:time] = Time.now

    if (thread_name = Thread.current.name)
      out[:thread] = thread_name
    end

    raw = (JSON.generate(out) << "\n").freeze
    @@mutex.synchronize do
      $stdout.write(raw)
    end
    nil
  end
end
