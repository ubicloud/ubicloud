# frozen_string_literal: true

require_relative "../lib/runner_metrics_agent"
require "tmpdir"

RSpec.describe RunnerMetricsAgent do
  subject(:agent) { described_class.new("#{root}/metrics.raw", "#{root}/metrics") }

  let(:root) { Dir.mktmpdir }
  let(:now) { Time.utc(2026, 11, 2, 14, 0, 0) }

  after { FileUtils.rm_rf(root) }

  def slot(text)
    text.ljust(described_class::SLOT_SIZE - 1) + "\n"
  end

  def sample(seq)
    slot(%({"seq":#{seq},"sysstat":{"hosts":[]}}))
  end

  def write_disk(*slots)
    File.binwrite("#{root}/metrics.raw", slots.join.ljust(described_class::SLOT_SIZE * 4, "\0"))
  end

  def done_files
    Dir.children("#{root}/metrics/done").sort
  end

  describe "#entries" do
    it "returns valid samples ordered by seq, normalized to one line" do
      buffer = sample(2) + sample(1) + slot('{"seq":3,"sysstat":') + slot('{"seq":0,"sysstat":{}}') +
        slot('{"seq":"4","sysstat":{}}') + slot('{"seq":5,"sysstat":[]}') + slot("[5]") +
        slot('{"seq":6,"sysstat":' + ("[" * 12) + ("]" * 12) + "}") + "\0" * described_class::SLOT_SIZE

      expect(agent.entries(buffer)).to eq([[1, '{"seq":1,"sysstat":{"hosts":[]}}'], [2, '{"seq":2,"sysstat":{"hosts":[]}}']])
    end
  end

  describe "#tick" do
    it "writes the samples newer than the last written one into a done file" do
      write_disk(sample(1), sample(2))
      expect(agent.tick(now)).to eq(2)
      expect(File.read("#{root}/metrics/done/20261102T140000000000000.jsonl")).to eq(%({"seq":1,"sysstat":{"hosts":[]}}\n{"seq":2,"sysstat":{"hosts":[]}}\n))

      write_disk(sample(1), sample(2), sample(3))
      expect(agent.tick(now + 5)).to eq(1)
      expect(File.read("#{root}/metrics/done/20261102T140005000000000.jsonl")).to eq(%({"seq":3,"sysstat":{"hosts":[]}}\n))

      expect(agent.tick(now + 10)).to eq(0)
      expect(done_files).to eq(["20261102T140000000000000.jsonl", "20261102T140005000000000.jsonl"])
    end

    it "starts over when the guest does" do
      write_disk(sample(1), sample(2), sample(3))
      agent.tick(now)

      write_disk(sample(1))
      expect(agent.tick(now + 5)).to eq(1)
    end

    it "keeps the newest files" do
      stub_const("#{described_class}::MAX_FILES", 2)
      3.times do |i|
        write_disk(sample(i + 1))
        agent.tick(now + i)
      end

      expect(done_files).to eq(["20261102T140001000000000.jsonl", "20261102T140002000000000.jsonl"])
    end
  end

  describe "#run" do
    it "writes new samples, then sleeps for the interval, until stopped" do
      write_disk(sample(1))
      expect(agent).to receive(:sleep).with(5).and_raise(StopIteration)

      agent.run
      expect(done_files.map { |file| File.read("#{root}/metrics/done/#{file}") }).to eq([%({"seq":1,"sysstat":{"hosts":[]}}\n)])
    end
  end
end
