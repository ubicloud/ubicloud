# frozen_string_literal: true

require "json"

class Clog
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

    if (thread_name = Thread.current.name)
      out[:thread] = thread_name
    end

    puts JSON.generate(out)
    nil
  end
end
