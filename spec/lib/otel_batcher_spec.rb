# frozen_string_literal: true

RSpec.describe OtelBatcher do
  describe "#can use generic otel_batcher" do
    let(:otel_batcher) { described_class.new("https://localhost:4318") }
    let(:connection) { otel_batcher.ensure_connection }

    after { otel_batcher.stop }

    describe "#send_batch" do
      it "prints failure message when response is not success" do
        expect(connection).to receive(:post).and_return(instance_double(Excon::Response, status: 400, reason_phrase: "Bad Request"))
        expect(otel_batcher).to receive(:puts).with("Failed to send logs: 400 Bad Request")

        otel_batcher.send_batch(["test log"])
      end

      it "prints error message and closes connection when request raises an unexpected exception" do
        expect(connection).to receive(:post).and_raise(StandardError, "Unexpected Error")
        expect(otel_batcher).to receive(:puts).with("Error sending batch: Unexpected Error")
        expect(otel_batcher).to receive(:close_connection).at_least(:once).and_call_original

        otel_batcher.send_batch(["test log"])
      end

      it "does not print any extra message when request is successful" do
        expect(connection).to receive(:post).and_return(instance_double(Excon::Response, status: 200))
        expect(otel_batcher).not_to receive(:puts)

        otel_batcher.send_batch(["test log"])
      end

      it "sends the correct OTLP JSON payload" do
        expect(connection).to receive(:post).and_wrap_original do |_m, **kwargs|
          body = JSON.parse(kwargs[:body])
          expect(body["resourceLogs"].length).to eq(1)
          expect(body["resourceLogs"][0]["scopeLogs"][0]["logRecords"]).to eq(["test record"])
          expect(kwargs[:headers]["Content-Type"]).to eq("application/json")
          instance_double(Excon::Response, status: 200)
        end

        otel_batcher.send_batch(["test record"])
      end

      it "includes default resource attributes in the payload" do
        batcher = described_class.new("https://localhost:4318", default_resource_attrs: {"service.name" => "test-app"})
        batcher_connection = batcher.ensure_connection

        expect(batcher_connection).to receive(:post).and_wrap_original do |_m, **kwargs|
          body = JSON.parse(kwargs[:body])
          attrs = body["resourceLogs"][0]["resource"]["attributes"]
          expect(attrs).to include({"key" => "service.name", "value" => {"stringValue" => "test-app"}})
          instance_double(Excon::Response, status: 200)
        end

        batcher.send_batch(["test record"])
      ensure
        batcher.stop
      end

      it "exits early if the batch is empty" do
        expect(connection).not_to receive(:post)

        otel_batcher.send_batch([])
      end

      it "exits when failures exceed the allowed limit" do
        allow(connection).to receive(:post).and_return(instance_double(Excon::Response, status: 400, reason_phrase: "Bad Request"))
        allow(otel_batcher).to receive(:puts)

        4.times { otel_batcher.send_batch(["test log"]) }
        expect { otel_batcher.send_batch(["test log"]) }.to raise_error(SystemExit)
      end
    end

    describe "#log" do
      it "enqueues a log record with the correct OTLP structure" do
        otel_batcher.log("hello world", app: "test", level: "error", custom_key: "custom_val")

        record = otel_batcher.instance_variable_get(:@input_queue).pop(timeout: 1)
        expect(record[:severityText]).to eq("ERROR")
        expect(record[:body]).to eq({stringValue: "hello world"})
        expect(record[:timeUnixNano]).to be_a(String)
        expect(record[:attributes]).to include(
          {key: "app", value: {stringValue: "test"}},
          {key: "custom_key", value: {stringValue: "custom_val"}}
        )
      end
    end

    describe "#ensure_connection" do
      it "creates a new Excon connection" do
        expect(Excon).to receive(:new).with("https://localhost:4318/v1/logs", persistent: true).and_call_original
        otel_batcher.ensure_connection
      end

      it "returns existing connection if there is one" do
        expect(Excon).to receive(:new).exactly(:once).and_call_original

        otel_batcher.ensure_connection
        otel_batcher.ensure_connection
      end
    end
  end

  describe "#processor thread" do
    let(:otel_batcher) { described_class.new("https://localhost:4318", flush_interval: 10000, max_batch_size: 100) }
    let(:connection) { otel_batcher.ensure_connection }

    after { otel_batcher.stop }

    before do
      allow(connection).to receive(:post).and_return(instance_double(Excon::Response, status: 200))
    end

    it "sends batch when input queue is closed" do
      expect(otel_batcher).to receive(:send_batch).exactly(:once)
      otel_batcher.stop
    end

    it "adds to batch if not over the limit" do
      expected = false
      q = Queue.new
      otel_batcher.instance_variable_set(:@max_batch_size, 2)
      otel_batcher.define_singleton_method(:send_batch) do |batch|
        raise unless expected

        q.push(batch.dup)
        super(batch)
      end
      otel_batcher.log("test log")
      expected = true
      otel_batcher.log("test log 2")
      expect(q.pop.map { it[:body][:stringValue] }).to eq ["test log", "test log 2"]
    end

    it "sends the batch when flush interval is exceeded" do
      q = Queue.new

      expect(otel_batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        # This guarantees that the flush interval is exceeded
        otel_batcher.instance_variable_set(:@flush_interval, -1)
        q.push(true)
        m.call(*args)
      end

      expect(otel_batcher).to receive(:send_batch).at_least(:once).and_wrap_original do |m, *args|
        # Reset flush interval to a high value to avoid immediate re-flush(es)
        otel_batcher.instance_variable_set(:@flush_interval, 10000)
        q.push(true)
        m.call(*args)
      end

      otel_batcher.log("test log")

      2.times { expect(q.pop(timeout: 5)).to be true }
      expect(q.empty?).to be(true)
    end

    it "sends the batch when max batch size is exceeded" do
      q = Queue.new

      expect(otel_batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        # This guarantees that max batch size is exceeded
        otel_batcher.instance_variable_set(:@max_batch_size, 1)
        q.push(true)
        m.call(*args)
      end

      first_time = true
      expect(otel_batcher).to receive(:send_batch).at_least(:once).and_wrap_original do |m, batch|
        # Reset max batch size to a high value to avoid immediate re-send(s)
        otel_batcher.instance_variable_set(:@max_batch_size, 100)
        q.push(true)
        m.call(batch)
        if first_time
          first_time = false
          batch << "test log"
        end
      end

      otel_batcher.log("test log")

      2.times { expect(q.pop(timeout: 5)).to be true }
      expect(q.empty?).to be(true)
    end

    it "does not send the batch until one of the pre-conditions are satisfied" do
      called = false
      otel_batcher.define_singleton_method(:send_batch) do
        called = true
        super(it)
      end
      otel_batcher.log("test log")
      expect(called).to be false
    end

    it "logs error in case of an exception during batch processing" do
      q = Queue.new

      expect(otel_batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        m.call(*args)
        true
      end

      expect(otel_batcher.instance_variable_get(:@input_queue)).to receive(:empty?).and_raise(StandardError, "Unexpected error")
      expect(otel_batcher).to receive(:puts).with("Error in processor: Unexpected error").ordered
      expect(otel_batcher).to receive(:puts).with(anything).ordered
      expect(otel_batcher).to receive(:exit) do |status|
        expect(status).to eq 1
        q.push(true)
        raise StopIteration
      end

      otel_batcher.log("test log")

      expect(q.pop(timeout: 5)).to be true
      expect(q.empty?).to be(true)
    end
  end

  describe "#close_connection" do
    it "handles closing when connection is nil" do
      otel_batcher = described_class.new("https://localhost:4318")

      expect { otel_batcher.close_connection }.not_to raise_error
    ensure
      otel_batcher.stop
    end
  end

  describe "#initialize" do
    it "strips trailing slash from endpoint" do
      batcher = described_class.new("https://localhost:4318/")
      expect(batcher.instance_variable_get(:@endpoint)).to eq("https://localhost:4318/v1/logs")
    ensure
      batcher.stop
    end
  end
end
