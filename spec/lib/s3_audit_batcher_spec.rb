# frozen_string_literal: true

require "aws-sdk-s3"

RSpec.describe S3AuditBatcher do
  let(:client) { instance_double(Aws::S3::Client) }
  let(:retain_until) { Time.now + 1000 }

  describe "#send_batch" do
    let(:batcher) { described_class.new(client:, bucket: "audit", key_prefix: "pry/2026-06-19/op/sess", retain_until:) }

    after { batcher.stop }

    it "exits early if the batch is empty" do
      expect(client).not_to receive(:put_object)

      batcher.send_batch([])
    end

    it "writes a write-once, object-locked, encrypted object and clears the batch" do
      expect(client).to receive(:put_object).with(
        hash_including(
          bucket: "audit",
          key: "pry/2026-06-19/op/sess/000000.jsonl",
          body: "{\"line\":\"a\"}\n{\"line\":\"b\"}",
          content_type: "application/x-ndjson",
          server_side_encryption: "AES256",
          object_lock_mode: "COMPLIANCE",
          object_lock_retain_until_date: retain_until,
          if_none_match: "*",
          checksum_algorithm: "CRC32",
        ),
      )

      batch = [{line: "a"}, {line: "b"}]
      batcher.send_batch(batch)
      expect(batch).to be_empty
    end

    it "increments the object sequence per successful batch" do
      keys = []
      allow(client).to receive(:put_object) { |args| keys << args[:key] }

      batcher.send_batch([{line: "a"}])
      batcher.send_batch([{line: "b"}])

      expect(keys).to eq ["pry/2026-06-19/op/sess/000000.jsonl", "pry/2026-06-19/op/sess/000001.jsonl"]
    end

    it "prints an error and keeps the batch on failure" do
      expect(client).to receive(:put_object).and_raise(StandardError, "boom")
      expect(batcher).to receive(:puts).with("Error sending audit batch: boom")

      batch = [{line: "a"}]
      batcher.send_batch(batch)
      expect(batch).not_to be_empty
    end

    it "exits the process when failures exceed the limit (fail-closed)" do
      allow(client).to receive(:put_object).and_raise(StandardError, "boom")
      allow(batcher).to receive(:puts)

      4.times { batcher.send_batch([{line: "a"}]) }
      expect { batcher.send_batch([{line: "a"}]) }.to raise_error(SystemExit)
    end
  end

  describe "#processor thread" do
    let(:batcher) { described_class.new(client:, bucket: "audit", key_prefix: "p", retain_until:, flush_interval: 10000, max_batch_size: 100) }

    after { batcher.stop }

    before { allow(client).to receive(:put_object) }

    it "sends batch when input queue is closed" do
      expect(batcher).to receive(:send_batch).exactly(:once)
      batcher.stop
    end

    it "adds to batch if not over the limit" do
      expected = false
      q = Queue.new
      batcher.instance_variable_set(:@max_batch_size, 2)
      batcher.define_singleton_method(:send_batch) do |batch|
        raise unless expected

        q.push(batch.dup)
        super(batch)
      end
      batcher.log("test log")
      expected = true
      batcher.log("test log 2")
      expect(q.pop.map { it[:line] }).to eq ["test log", "test log 2"]
    end

    it "sends the batch when flush interval is exceeded" do
      q = Queue.new

      expect(batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        batcher.instance_variable_set(:@flush_interval, -1)
        q.push(true)
        m.call(*args)
      end

      expect(batcher).to receive(:send_batch).at_least(:once).and_wrap_original do |m, *args|
        batcher.instance_variable_set(:@flush_interval, 10000)
        q.push(true)
        m.call(*args)
      end

      batcher.log("test log")

      2.times { expect(q.pop(timeout: 5)).to be true }
      expect(q.empty?).to be(true)
    end

    it "sends the batch when max batch size is exceeded" do
      q = Queue.new

      expect(batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        batcher.instance_variable_set(:@max_batch_size, 1)
        q.push(true)
        m.call(*args)
      end

      first_time = true
      expect(batcher).to receive(:send_batch).at_least(:once).and_wrap_original do |m, batch|
        batcher.instance_variable_set(:@max_batch_size, 100)
        q.push(true)
        m.call(batch)
        if first_time
          first_time = false
          batch << {line: "test log"}
        end
      end

      batcher.log("test log")

      2.times { expect(q.pop(timeout: 5)).to be true }
      expect(q.empty?).to be(true)
    end

    it "does not send the batch until one of the pre-conditions are satisfied" do
      called = false
      batcher.define_singleton_method(:send_batch) do
        called = true
        super(it)
      end
      batcher.log("test log")
      expect(called).to be false
    end

    it "logs error in case of an exception during batch processing" do
      q = Queue.new

      expect(batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        m.call(*args)
        true
      end

      expect(batcher.instance_variable_get(:@input_queue)).to receive(:empty?).and_raise(StandardError, "Unexpected error")
      expect(batcher).to receive(:puts).with("Error in processor: Unexpected error").ordered
      expect(batcher).to receive(:puts).with(anything).ordered
      expect(batcher).to receive(:exit) do |status|
        expect(status).to eq 1
        q.push(true)
        raise StopIteration
      end

      batcher.log("test log")

      expect(q.pop(timeout: 5)).to be true
      expect(q.empty?).to be(true)
    end
  end
end
