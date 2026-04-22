# frozen_string_literal: true

module PostgresConfig
  # Quote and escape a value for postgresql.conf single-quoted string syntax.
  # Backslashes and single quotes are the only characters that need escaping.
  def self.quote_value(v)
    "'#{v.to_s.gsub("\\") { "\\\\" }.gsub("'", "''")}'"
  end

  # Format a hash of config key-value pairs for postgresql.conf.
  def self.format(config)
    config.map { |k, v| "#{k} = #{quote_value(v)}" }.join("\n")
  end
end
