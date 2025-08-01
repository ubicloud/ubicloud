# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "socket"

class LogDnaBatcher
  def initialize(api_key, base_url: "https://logs.logdna.com/logs/ingest", default_metadata: {"pid" => Process.pid}, flush_interval: 0.5, max_batch_size: 5)
    @api_key = api_key
    @flush_interval = flush_interval
    @max_batch_size = max_batch_size
    @input_queue = Queue.new
    @http = nil
    @base_url = URI.parse(base_url)
    @default_metadata = default_metadata.dup.freeze
    @batch_send_failure_count = 0

    start_processor
  end

  def log(line, timestamp: (Time.now.to_f * 1000).to_i, app: nil, level: "info", **meta)
    meta = @default_metadata.dup.merge!(meta)

    data = {line:, timestamp:, app:, level:, meta:}.compact
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
      http = ensure_connection

      request = Net::HTTP::Post.new(@base_url.to_s + "?hostname=#{Socket.gethostname}")
      request.basic_auth(@api_key, "")
      request["Content-Type"] = "application/json; charset=UTF-8"
      request["Connection"] = "keep-alive"
      request.body = {lines: batch}.to_json

      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        batch.clear
        @batch_send_failure_count = 0
      else
        @batch_send_failure_count += 1
        puts "Failed to send logs: #{response.code} #{response.message}"
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
    return @http if @http&.started?

    close_connection if @http

    @http = Net::HTTP.new(@base_url.host, @base_url.port)
    @http.use_ssl = @base_url.scheme == "https"
    @http.keep_alive_timeout = 30
    @http.start
    @http
  end

  def close_connection
    @http.finish if @http&.started?
    @http = nil
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
