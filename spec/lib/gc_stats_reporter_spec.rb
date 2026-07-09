# frozen_string_literal: true

require_relative "../spec_helper"
require "tempfile"

RSpec.describe GcStatsReporter do
  let(:reporter) { described_class.new(key: "test", report_every: 30, status_file: @status_file || "/proc/self/status") }

  after do
    expect(reporter.shutdown!).to be_nil
  end

  it "uses defaults for key, report_every, and status_file" do
    expect(described_class.new.shutdown!).to be_nil
  end

  it "#shutdown! works if the thread hasn't been started" do
    expect(reporter.shutdown!).to be_nil
  end

  it "#shutdown! works if the thread has been started" do
    thread = reporter.run_thread
    expect(reporter.shutdown!).to be_nil
    expect(thread.alive?).to be false
    expect(thread.value).to be true
  end

  it "#run_thread emits if run method fails" do
    expect(reporter).to receive(:run).and_raise(RuntimeError)
    expect(Clog).to receive(:emit).with("test failure", Hash)
    thread = reporter.run_thread
    expect(thread.join(1).value).to be false
  end

  it "#run emits GC stats until shutdown" do
    emitted = Queue.new
    expect(Clog).to receive(:emit).at_least(:once) do |message, hash|
      expect(message).to eq "test"
      emitted.push(hash["test"])
    end
    thread = reporter.run_thread
    data = emitted.pop
    expect(data["pid"]).to eq Process.pid
    expect(reporter.shutdown!).to be_nil
    expect(thread.value).to be true
  end

  it "#stats returns GC statistics and process memory usage" do
    data = reporter.stats
    described_class::GC_STAT_KEYS.each do |key|
      expect(data[key.to_s]).to be_a Integer
    end
    expect(data["pid"]).to eq Process.pid
    expect(data["rss_kb"]).to be_a Integer
  end

  it "#stats parses RSS and swap usage from the status file" do
    Tempfile.create("status") do |file|
      file.write("Name:\ttest\nVmRSS:\t    123 kB\nVmSwap:\t      4 kB\n")
      file.flush
      @status_file = file.path
      data = reporter.stats
      expect(data["rss_kb"]).to eq 123
      expect(data["swap_kb"]).to eq 4
    end
  end

  it "#stats omits process memory usage if the status file does not exist" do
    @status_file = "/nonexistent-status-file"
    data = reporter.stats
    expect(data).not_to have_key("rss_kb")
    expect(data).not_to have_key("swap_kb")
  end
end
