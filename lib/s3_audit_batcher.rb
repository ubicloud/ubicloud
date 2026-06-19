# frozen_string_literal: true

require "json"

# Ships audit log lines to an S3 bucket with Object Lock (Compliance mode),
# one immutable, write-once object per flushed batch. Fail-closed: repeated
# write failures exit the process so no unaudited session can continue.
class S3AuditBatcher
  def initialize(client:, bucket:, key_prefix:, retain_until:, flush_interval: 0.5, max_batch_size: 5)
    @client = client
    @bucket = bucket
    @key_prefix = key_prefix
    @retain_until = retain_until
    @flush_interval = flush_interval
    @max_batch_size = max_batch_size
    @input_queue = Queue.new
    @seq = 0
    @batch_send_failure_count = 0

    start_processor
  end

  def log(line, timestamp: (Time.now.to_f * 1000).to_i, app: nil, level: "info", **meta)
    @input_queue.push({line:, timestamp:, app:, level:, **meta}.compact)
  end

  def stop
    @input_queue.close
    @processor_thread.join(@flush_interval + 5)
  end

  def send_batch(batch)
    return if batch.empty?

    begin
      @client.put_object(
        bucket: @bucket,
        key: "#{@key_prefix}/#{format("%06d", @seq)}.jsonl",
        body: batch.map { JSON.generate(it) }.join("\n"),
        content_type: "application/x-ndjson",
        server_side_encryption: "AES256",
        object_lock_mode: "COMPLIANCE",
        object_lock_retain_until_date: @retain_until,
        if_none_match: "*",
      )
      @seq += 1
      batch.clear
      @batch_send_failure_count = 0
    rescue => e
      @batch_send_failure_count += 1
      puts "Error sending audit batch: #{e.message}"
    end

    if @batch_send_failure_count >= 5
      puts "Too many failures sending audit logs, stopping the batcher."
      exit(1)
    end
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
