# frozen_string_literal: true

require "excon"
require "json"

class OtelBatcher
  def initialize(endpoint, default_resource_attrs: {}, flush_interval: 0.5, max_batch_size: 5)
    @flush_interval = flush_interval
    @max_batch_size = max_batch_size
    @input_queue = Queue.new
    @connection = nil
    @endpoint = "#{endpoint.chomp("/")}/v1/logs"
    @default_resource_attrs = default_resource_attrs.freeze
    @batch_send_failure_count = 0

    start_processor
  end

  def log(line, timestamp: (Time.now.to_f * 1_000_000_000).to_i, app: nil, level: "info", **attrs)
    severity = level.upcase
    attrs["app"] = app if app

    data = {
      timeUnixNano: timestamp.to_s,
      severityText: severity,
      body: {stringValue: line},
      attributes: attrs.map { |k, v| {key: k.to_s, value: {stringValue: v.to_s}} },
    }
    @input_queue.push(data)
  end

  def stop
    @input_queue.close
    @processor_thread.join(@flush_interval + 5)
    close_connection
  end

  def send_batch(batch)
    return if batch.empty?

    begin
      connection = ensure_connection

      payload = {
        resourceLogs: [{
          resource: {
            attributes: @default_resource_attrs.map { |k, v| {key: k.to_s, value: {stringValue: v.to_s}} },
          },
          scopeLogs: [{
            logRecords: batch,
          }],
        }],
      }

      response = connection.post(
        path: URI.parse(@endpoint).path,
        headers: {"Content-Type" => "application/json"},
        body: JSON.generate(payload),
      )

      if response.status == 200
        batch.clear
        @batch_send_failure_count = 0
      else
        @batch_send_failure_count += 1
        puts "Failed to send logs: #{response.status} #{response.reason_phrase}"
      end
    rescue => e
      @batch_send_failure_count += 1
      puts "Error sending batch: #{e.message}"
      close_connection
    end

    if @batch_send_failure_count >= 5
      puts "Too many failures sending logs, stopping the batcher."
      exit(1)
    end
  end

  def ensure_connection
    return @connection if @connection

    @connection = Excon.new(@endpoint, persistent: true)
  end

  def close_connection
    @connection&.reset
    @connection = nil
  end

  private

  def start_processor
    @processor_thread = Thread.new do
      batch = []
      last_flush_time = Time.now

      loop do
        if (item = @input_queue.pop(timeout: @flush_interval))
          batch << item
        end

        input_queue_is_closed = @input_queue.closed? && @input_queue.empty?
        flush_interval_is_exceeded = (Time.now - last_flush_time) >= @flush_interval
        max_batch_size_is_exceeded = batch.size >= @max_batch_size

        if input_queue_is_closed || flush_interval_is_exceeded || max_batch_size_is_exceeded
          send_batch(batch)

          if batch.empty?
            last_flush_time = Time.now
            break if input_queue_is_closed
          end
        end
      rescue => e
        puts "Error in processor: #{e.message}"
        puts e.backtrace
        exit(1)
      end
    end
  end
end
