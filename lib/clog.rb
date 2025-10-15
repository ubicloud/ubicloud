# frozen_string_literal: true

require "json"
require "sequel/model"

class Clog
  MUTEX = Mutex.new

  def self.emit(message)
    out = if block_given?
      case metadata = yield
      when Hash
        metadata
      when Array
        metadata.reduce({}) do |hash, item|
          case item
          when Hash
            hash.merge(item)
          when Sequel::Model
            hash.merge(serialize_model(item))
          else
            hash.merge({invalid_type: item.class.to_s})
          end
        end
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
    MUTEX.synchronize do
      $stdout.write(raw)
    end
    nil
  end

  private_class_method def self.serialize_model(model)
    {model.class.table_name => model.values.except(*model.class.redacted_columns)}
  end
end
