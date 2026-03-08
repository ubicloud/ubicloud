# frozen_string_literal: true

module Toml
  def toml_section(name, hash)
    "[#{name}]\n#{hash.map { |k, v| "#{k} = #{toml_value(v)}" }.join("\n")}\n"
  end

  def toml_value(v)
    case v
    when String then toml_str(v)
    when Array then "[#{v.map { |e| toml_value(e) }.join(", ")}]"
    else v
    end
  end

  def toml_str(value)
    # From TOML specs:
    # > Basic strings are surrounded by quotation marks ("). Any Unicode
    # > character may be used except those that must be escaped: quotation mark,
    # > backslash, and the control characters other than tab (U+0000 to U+0008,
    # > U+000A to U+001F, U+007F).
    #
    # See https://toml.io/en/v1.0.0#string
    h = {
      "\b" => '\\b',
      "\n" => '\\n',
      "\f" => '\\f',
      "\r" => '\\r',
      '"' => '\\"',
      "\\" => "\\\\"
    }
    h.default_proc = proc { |_, ch| format('\\u%04X', ch.ord) }
    escaped = value.gsub(/[\x00-\x08\x0A-\x1F\x7F"\\]/, h)
    "\"#{escaped}\""
  end
end
