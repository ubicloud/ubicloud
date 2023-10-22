# frozen_string_literal: true

require "json"

class Clog
  @@mutex = Mutex.new

  def self.emit(message)
    out = if block_given?
      case metadata = yield
      when Hash
        metadata
      when Sequel::Model
        serialize_model(metadata)
      else
        {invalid_type: metadata.class.to_s}
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

  private_class_method def self.serialize_model(model)
    {model.class.table_name => model.values.except(*model.class.redacted_columns)}
  end
end
