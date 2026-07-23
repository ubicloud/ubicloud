# frozen_string_literal: true

require "json"
require "sequel/model"

class Clog
  MUTEX = Mutex.new

  def self.emit(message, metadata = {})
    # :nocov:
    # Cannot use spec passing block to cover this, or Ruby produces a warning
    raise "Clog.emit no longer takes a block" if block_given?
    # :nocov:

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

    out[:message] = message
    out[:time] = Time.now

    if (thread_name = Thread.current.name)
      out[:thread] = thread_name
    end

    write(out)
  end

  private_class_method def self.write(out)
    raw = generate_line(out)

    return if Config.test?

    MUTEX.synchronize do
      $stdout.write(raw)
    end

    nil
  end

  # Command stderr/stdout can carry bytes that are not valid UTF-8, which
  # JSON.generate rejects. Output is text in the normal case, so scrub only on
  # the rare failure rather than walking every payload on every emit.
  private_class_method def self.generate_line(out)
    (JSON.generate(out) << "\n").freeze
  rescue JSON::GeneratorError
    (JSON.generate(scrub(out)) << "\n").freeze
  end

  private_class_method def self.scrub(value)
    case value
    when String
      (value.encoding == Encoding::UTF_8 && value.valid_encoding?) ? value : value.b.force_encoding(Encoding::UTF_8).scrub
    when Hash
      value.transform_values { scrub(it) }
    when Array
      value.map { scrub(it) }
    else
      value
    end
  end

  # Only works for models using the ResourceMethods plugin.
  private_class_method def self.serialize_model(model)
    hash = model.inspect_values_hash
    hash[:id] = model.ubid
    hash
  end
end
