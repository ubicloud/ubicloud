# frozen_string_literal: true

RSpec.describe LogDnaBatcher do
  describe "#can use generic log_dna_batcher" do
    let(:log_dna_batcher) { described_class.new("dummy-key") }
    let(:http) { log_dna_batcher.ensure_connection }

    after { log_dna_batcher.stop }

    describe "#send_batch" do
      it "prints failure message when response is not success" do
        expect(http).to receive(:request).and_return(Net::HTTPBadRequest.new(nil, 400, "Bad Request"))
        expect(log_dna_batcher).to receive(:puts).with("Failed to send logs: 400 Bad Request")

        log_dna_batcher.send_batch(["test log"])
      end

      it "prints error message and closes connection when request raises an unexpected exception" do
        expect(http).to receive(:request).and_raise(StandardError, "Unexpected Error")
        expect(log_dna_batcher).to receive(:puts).with("Error sending batch: Unexpected Error")
        expect(log_dna_batcher).to receive(:close_connection).at_least(:once).and_call_original

        log_dna_batcher.send_batch(["test log"])
      end

      it "does not print any extra message when request is successful" do
        expect(http).to receive(:request).and_return(Net::HTTPSuccess.new(nil, nil, nil))
        expect(log_dna_batcher).not_to receive(:puts)

        log_dna_batcher.send_batch(["test log"])
      end

      it "exits early if the batch is empty" do
        expect(http).not_to receive(:request)

        log_dna_batcher.send_batch([])
      end

      it "exits when failures exceed the allowed limit" do
        allow(http).to receive(:request).and_return(Net::HTTPBadRequest.new(nil, 400, "Bad Request"))
        allow(log_dna_batcher).to receive(:puts)

        4.times { log_dna_batcher.send_batch(["test log"]) }
        expect { log_dna_batcher.send_batch(["test log"]) }.to raise_error(SystemExit)
      end
    end

    describe "#ensure_connection" do
      it "recreates a connection if there is a connection but it is not started" do
        log_dna_batcher.instance_variable_set(:@http, Net::HTTP.new("http://localhost"))
        expect(Net::HTTP).to receive(:new).and_call_original
        log_dna_batcher.ensure_connection
      end

      it "returns existing connection if there is one and it is started" do
        log_dna_batcher = described_class.new("dummy-key")
        expect(Net::HTTP).to receive(:new).exactly(:once).and_call_original

        log_dna_batcher.ensure_connection
        log_dna_batcher.ensure_connection
      ensure
        log_dna_batcher.stop
      end
    end
  end

  describe "#processor thread" do
    let(:log_dna_batcher) { described_class.new("dummy-key", base_url: "https://localhost/logdna/ingest", flush_interval: 10000, max_batch_size: 100) }
    let(:http) { log_dna_batcher.ensure_connection }

    after { log_dna_batcher.stop }

    before do
      allow(http).to receive(:request).and_return(Net::HTTPSuccess.new(nil, nil, nil))
    end

    it "sends batch when input queue is closed" do
      expect(log_dna_batcher).to receive(:send_batch).exactly(:once)
      log_dna_batcher.stop
    end

    it "adds to batch if not over the limit" do
      expected = false
      q = Queue.new
      log_dna_batcher.instance_variable_set(:@max_batch_size, 2)
      log_dna_batcher.define_singleton_method(:send_batch) do |batch|
        raise unless expected

        q.push(batch.dup)
        super(batch)
      end
      log_dna_batcher.log("test log")
      expected = true
      log_dna_batcher.log("test log 2")
      expect(q.pop.map { it[:line] }).to eq ["test log", "test log 2"]
    end

    it "sends the batch when flush interval is exceeded" do
      q = Queue.new

      expect(log_dna_batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        # This guarantees that the flush interval is exceeded
        log_dna_batcher.instance_variable_set(:@flush_interval, -1)
        q.push(true)
        m.call(*args)
      end

      expect(log_dna_batcher).to receive(:send_batch).at_least(:once).and_wrap_original do |m, *args|
        # Reset flush interval to a high value to avoid immediate re-flush(es)
        log_dna_batcher.instance_variable_set(:@flush_interval, 10000)
        q.push(true)
        m.call(*args)
      end

      log_dna_batcher.log("test log")

      2.times { expect(q.pop(timeout: 5)).to be true }
      expect(q.empty?).to be(true)
    end

    it "sends the batch when max batch size is exceeded" do
      q = Queue.new

      expect(log_dna_batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        # This guarantees that max batch size is exceeded
        log_dna_batcher.instance_variable_set(:@max_batch_size, 1)
        q.push(true)
        m.call(*args)
      end

      first_time = true
      expect(log_dna_batcher).to receive(:send_batch).at_least(:once).and_wrap_original do |m, batch|
        # Reset max batch size to a high value to avoid immediate re-send(s)
        log_dna_batcher.instance_variable_set(:@max_batch_size, 100)
        q.push(true)
        m.call(batch)
        if first_time
          first_time = false
          batch << "test log"
        end
      end

      log_dna_batcher.log("test log")

      2.times { expect(q.pop(timeout: 5)).to be true }
      expect(q.empty?).to be(true)
    end

    it "does not send the batch until one of the pre-conditions are satisfied" do
      called = false
      log_dna_batcher.define_singleton_method(:send_batch) do
        called = true
        super(it)
      end
      log_dna_batcher.log("test log")
      expect(called).to be false
    end

    it "logs error in case of an exception during batch processing" do
      q = Queue.new

      expect(log_dna_batcher.instance_variable_get(:@input_queue)).to receive(:closed?).at_least(:once).and_wrap_original do |m, *args|
        m.call(*args)
        true
      end

      expect(log_dna_batcher.instance_variable_get(:@input_queue)).to receive(:empty?).and_raise(StandardError, "Unexpected error")
      expect(log_dna_batcher).to receive(:puts).with("Error in processor: Unexpected error").ordered
      expect(log_dna_batcher).to receive(:puts).with(anything).ordered
      expect(log_dna_batcher).to receive(:exit) do |status|
        expect(status).to eq 1
        q.push(true)
        raise StopIteration
      end

      log_dna_batcher.log("test log")

      expect(q.pop(timeout: 5)).to be true
      expect(q.empty?).to be(true)
    end
  end

  describe "#close_connection" do
    it "handles closing when http is nil" do
      log_dna_batcher = described_class.new("dummy-key", base_url: "https://localhost/logdna/ingest?param=test")

      expect { log_dna_batcher.close_connection }.not_to raise_error
    ensure
      log_dna_batcher.stop
    end
  end
end
