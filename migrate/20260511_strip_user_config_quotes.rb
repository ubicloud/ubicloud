# frozen_string_literal: true

Sequel.migration do
  up do
    has_unsupported_escape = lambda do |inner|
      i = 0
      while i < inner.length
        if inner[i] == "\\"
          nxt = inner[i + 1]
          return true if nxt != "\\" && nxt != "'"
          i += 2
        elsif inner[i] == "'" && inner[i + 1] == "'"
          i += 2
        else
          i += 1
        end
      end
      false
    end

    unquote = ->(v) { v[1...-1].gsub("''", "'").gsub("\\'", "'").gsub("\\\\") { "\\" } }

    from(:postgres_resource).select(:id, :user_config).each do |row|
      user_config = row[:user_config]
      next if user_config.nil? || user_config.empty?

      changed = false
      cleaned = user_config.each_with_object({}) do |(k, v), acc|
        if v.is_a?(String) && v.length >= 2 && v.start_with?("'") && v.end_with?("'")
          inner = v[1...-1]
          if has_unsupported_escape.call(inner)
            raise Sequel::Error, "postgres_resource #{row[:id]} key #{k.inspect}: unsupported escape in #{v.inspect}"
          end
          acc[k] = unquote.call(v)
          changed = true
        elsif v.is_a?(String) && v.start_with?("'") != v.end_with?("'")
          raise Sequel::Error, "postgres_resource #{row[:id]} key #{k.inspect}: mismatched single quote in #{v.inspect}"
        else
          acc[k] = v
        end
      end

      from(:postgres_resource).where(id: row[:id]).update(user_config: Sequel.pg_jsonb(cleaned)) if changed
    end
  end

  down do
    # No-op: forward-only. Pre-migration state mixed bare and manually-quoted
    # values; the boundary cannot be reconstructed from the bare-only post state.
  end
end
