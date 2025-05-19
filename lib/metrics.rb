# frozen_string_literal: true

module Metrics
  TimeSeries = Data.define(:labels, :query)
  MetricDefinition = Data.define(:name, :description, :unit, :series)

  POSTGRES_METRICS = {
    cpu_usage:
    MetricDefinition.new(
      name: "CPU Usage",
      description: "Percentage of CPU used by the system",
      unit: "%",
      series: [
        TimeSeries.new(
          labels: {},
          query: "avg(rate(node_cpu_seconds_total{mode=~\"(iowait|user|system|steal)\", ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m])) by (mode) * 100"
        )
      ]
    ),
    load_average:
    MetricDefinition.new(
      name: "Load Average",
      description: "System load average over different time periods",
      unit: nil,
      series: [
        TimeSeries.new(
          labels: {name: "1 minute"},
          query: "sum(node_load1{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"})"
        ),
        TimeSeries.new(
          labels: {name: "5 minutes"},
          query: "sum(node_load5{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"})"
        ),
        TimeSeries.new(
          labels: {name: "15 minutes"},
          query: "sum(node_load15{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"})"
        )
      ]
    ),
    memory_usage:
    MetricDefinition.new(
      name: "Memory Usage",
      description: "Total memory usage vs cache & buffers",
      unit: "%",
      series: [
        TimeSeries.new(
          labels: {name: "Used Memory"},
          query: "sum((1 - (node_memory_MemAvailable_bytes{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"} / node_memory_MemTotal_bytes{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"})) * 100)"
        ),
        TimeSeries.new(
          labels: {name: "Cache & Buffers"},
          query: "sum((node_memory_Cached_bytes{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"} + node_memory_Buffers_bytes{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}) / node_memory_MemTotal_bytes{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"} * 100)"
        )
      ]
    ),
    disk_usage:
    MetricDefinition.new(
      name: "Disk Usage",
      description: "Disk space utilization",
      unit: "%",
      series: [
        TimeSeries.new(
          labels: {name: "Used Space"},
          query: "100 - (sum(node_filesystem_avail_bytes{mountpoint=\"/dat\", ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"} / node_filesystem_size_bytes{mountpoint=\"/dat\", ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}) * 100)"
        )
      ]
    ),
    disk_io:
    MetricDefinition.new(
      name: "Disk I/O",
      description: "I/O operations per second",
      unit: "IOPS",
      series: [
        TimeSeries.new(
          labels: {name: "Reads"},
          query: "sum(rate(node_disk_reads_completed_total{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        ),
        TimeSeries.new(
          labels: {name: "Writes"},
          query: "sum(rate(node_disk_writes_completed_total{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        )
      ]
    ),
    network_traffic:
    MetricDefinition.new(
      name: "Network Traffic",
      description: "Incoming and outgoing network traffic",
      unit: "bytes/s",
      series: [
        TimeSeries.new(
          labels: {name: "Received"},
          query: "sum(rate(node_network_receive_bytes_total{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        ),
        TimeSeries.new(
          labels: {name: "Transmitted"},
          query: "sum(rate(node_network_transmit_bytes_total{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        )
      ]
    ),
    connection_count:
    MetricDefinition.new(
      name: "Connection Count",
      description: "Database activity metrics",
      unit: "count",
      series: [
        TimeSeries.new(
          labels: {name: "Active"},
          query: "sum(pg_stat_activity_count{state=\"active\", ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"})"
        ),
        TimeSeries.new(
          labels: {name: "Total"},
          query: "sum(pg_stat_activity_count{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"})"
        )
      ]
    ),
    cache_hit_ratio:
    MetricDefinition.new(
      name: "Cache Hit Ratio",
      description: "Percentage of cache hits vs reads",
      unit: "%",
      series: [
        TimeSeries.new(
          labels: {},
          query: "sum(rate(pg_stat_database_blks_hit{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m])) / (sum(rate(pg_stat_database_blks_hit{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m])) + sum(rate(pg_stat_database_blks_read{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))) * 100"
        )
      ]
    ),
    operation_throughput:
    MetricDefinition.new(
      name: "Operation Throughput",
      description: "Fetch, insert, update, delete operations per second",
      unit: "ops/s",
      series: [
        TimeSeries.new(
          labels: {name: "Fetch"},
          query: "sum(rate(pg_stat_database_tup_fetched{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        ),
        TimeSeries.new(
          labels: {name: "Insert"},
          query: "sum(rate(pg_stat_database_tup_inserted{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        ),
        TimeSeries.new(
          labels: {name: "Update"},
          query: "sum(rate(pg_stat_database_tup_updated{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        ),
        TimeSeries.new(
          labels: {name: "Delete"},
          query: "sum(rate(pg_stat_database_tup_deleted{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        )
      ]
    ),
    deadlocks:
    MetricDefinition.new(
      name: "Deadlocks",
      description: "Deadlocks per second",
      unit: "deadlocks/s",
      series: [
        TimeSeries.new(
          labels: {},
          query: "sum(rate(pg_stat_database_deadlocks{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\"}[1m]))"
        )
      ]
    ),
    database_size:
    MetricDefinition.new(
      name: "Database Size",
      description: "Top 5 databases by size",
      unit: "bytes",
      series: [
        TimeSeries.new(
          labels: {},
          query: "topk(5, sum(pg_database_size_bytes{ubicloud_resource_id=\"$ubicloud_resource_id\", ubicloud_resource_role=\"primary\", datname!~\"template0|template1\"}) by (datname))"
        )
      ]
    )
  }
end
