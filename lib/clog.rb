# frozen_string_literal: true

require "json"
require "sequel/model"

class Clog
  MUTEX = Mutex.new

  def self.emit(message, metadata = block_given? ? yield : {})
    out = case metadata
    when Hash
      metadata
    when Array
      hash = {}
      metadata.each do |item|
        case item
        when Hash
          hash.merge!(item)
        when Sequel::Model
          hash[item.class.table_name] = serialize_model(item)
        else
          hash[:invalid_type] = item.class.to_s
        end
      end
      hash
    when Sequel::Model
      {metadata.class.table_name => serialize_model(metadata)}
    else
      {invalid_type: metadata.class.to_s}
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
    model.values.except(*model.class.redacted_columns)
  end
end
