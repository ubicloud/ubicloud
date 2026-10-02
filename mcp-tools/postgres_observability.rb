# frozen_string_literal: true

module UbiMcp
  module Tools
    class GetPostgresMetrics < Tool
      tool_name "get_postgres_metrics"
      description "Resource and database metrics of a PostgreSQL database, each with its `unit` and with every series summarized (min, max, avg, last, sample count). A window spans at most 31 days and starts at most 31 days ago. Combine `points` with `key` to keep the result small."
      input_schema(
        properties: {
          ref: ref_property("pg"),
          key: {
            type: "string",
            enum: Metrics::POSTGRES_METRICS.keys.map(&:to_s),
            description: "Only this metric (default all)",
          },
          start: {type: "string", description: "Window start (RFC 3339); default 30 minutes ago"},
          end: {type: "string", description: "Window end (RFC 3339); default now"},
          points: {type: "boolean", default: false, description: "Add each series' values, downsampled to at most 24 points"},
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:, key: nil, start: nil, end: nil, points: false)
        path = resource_path(adapter, "postgres", ref, prefix: "pg")
        data = adapter.get("#{path}/metrics", {key:, start:, end:})
        metrics = data[:metrics].map do |metric|
          series = metric[:series].map { summarize(it, points) }
          {key: metric[:key], name: metric[:name], unit: metric[:unit], series:}
        end
        {window: {start:, end:}, metrics:}
      end

      class << self
        private

        def summarize(series, points)
          pairs = series[:values].filter_map do |ts, value|
            value = Float(value, exception: false)
            [ts, value] if value
          end
          summary = {labels: series[:labels], samples: pairs.size}
          return summary if pairs.empty?

          values = pairs.map(&:last)
          min, max = values.minmax
          summary.merge!(min:, max:, avg: values.sum / values.size, last: values.last)
          summary[:values] = downsample(pairs) if points
          summary
        end

        def downsample(pairs)
          pairs.group_by.with_index { |_, i| i * 24 / pairs.size }.map do |_, bucket|
            [bucket[0][0], bucket.sum(&:last) / bucket.size]
          end
        end
      end
    end

    class GetPostgresLogs < Tool
      LOG_ID_REGEXP = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

      tool_name "get_postgres_logs"
      description "Log lines of a PostgreSQL database, oldest first, with `next_cursor` for older lines. A query spans at most 24 hours and starts at most 7 days ago. When paging, pass the same `start` and `end` on every call, since their defaults move with each call."
      input_schema(
        properties: {
          ref: ref_property("pg"),
          start: {type: "string", description: "Window start (RFC 3339); default 30 minutes ago"},
          end: {type: "string", description: "Window end (RFC 3339); default now"},
          stream_name: {type: "string", enum: Option::POSTGRES_LOG_STREAM_OPTIONS, description: "Only lines from this log stream"},
          server_role: {type: "string", enum: Option::POSTGRES_LOG_SERVER_ROLE_OPTIONS, description: "Only lines from servers with this role"},
          severity_level: {type: "string", enum: Option::POSTGRES_LOG_LEVEL_OPTIONS, description: "Only lines with this severity"},
          query_pattern: {type: "string", maxLength: 200, description: "Substring to match in the message"},
          limit: {type: "integer", minimum: 1, maximum: 500, default: 50, description: "Maximum lines to return"},
          cursor: CURSOR_PROPERTY,
        },
        required: ["ref"],
        additionalProperties: false,
      )

      def self.run(adapter, ref:, start: nil, end: nil, stream_name: nil, server_role: nil, severity_level: nil, query_pattern: nil, limit: 50, cursor: nil)
        raise Invalid, "cursor must be the next_cursor of a previous result" if cursor && !LOG_ID_REGEXP.match?(cursor)

        path = resource_path(adapter, "postgres", ref, prefix: "pg")
        data = adapter.get("#{path}/logs", {start:, end:, stream_name:, server_role:, severity_level:, query_pattern:, max_log_lines: limit.to_i, pagination_key: cursor})
        {logs: data[:logs], next_cursor: data[:pagination_key]}
      end
    end
  end
end
