# frozen_string_literal: true

require_relative "../spec_helper"
require "puma"

RSpec.describe PumaWorkerRefresher do
  let(:worker_status) {
    [
      {pid: 101, index: 0, booted: true, started_at: "2026-11-25T10:00:00Z"},
      {pid: 102, index: 1, booted: true, started_at: "2026-11-25T09:00:00Z"},
      {pid: 103, index: 2, booted: true, started_at: "2026-11-25T09:00:00Z"},
      {pid: 104, index: 3, booted: false, started_at: "2026-11-25T08:00:00Z"},
      {pid: nil, index: 4, booted: false, started_at: "2026-11-25T07:00:00Z"},
    ]
  }

  let(:stats_calls) { Queue.new }

  let(:get_stats) {
    lambda do
      stats_calls.push(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      {worker_status:}
    end
  }

  let(:refresher) { @refresher = described_class.new(initial_sleep: 0, interval: 0, get_stats:) }

  after do
    expect(@refresher.shutdown!).to be_nil if @refresher
    Puma.stats_object = nil
  end

  def puma_stats(stats)
    Puma.stats_object = Struct.new(:stats).new(stats)
  end

  describe ".run" do
    env_keys = %w[WEB_CONCURRENCY DYNO PS].freeze

    around do |example|
      saved = ENV.to_h.slice(*env_keys)
      env_keys.each { ENV.delete(it) }
      example.run
    ensure
      env_keys.each { ENV.delete(it) }
      ENV.update(saved)
    end

    before do
      puma_stats({worker_status: []})
    end

    it "does not start a thread if WEB_CONCURRENCY is not set" do
      ENV["DYNO"] = "web.1"
      expect(described_class.run).to be_nil
    end

    it "does not start a thread if WEB_CONCURRENCY is not an integer" do
      ENV["WEB_CONCURRENCY"] = "x"
      ENV["DYNO"] = "web.1"
      expect(described_class.run).to be_nil
    end

    it "does not start a thread if WEB_CONCURRENCY is not positive" do
      ENV["WEB_CONCURRENCY"] = "0"
      ENV["DYNO"] = "web.1"
      expect(described_class.run).to be_nil
    end

    it "does not start a thread if DYNO and PS are not set" do
      ENV["WEB_CONCURRENCY"] = "7"
      expect(described_class.run).to be_nil
    end

    it "does not start a thread if not running on a web dyno" do
      ENV["WEB_CONCURRENCY"] = "7"
      ENV["DYNO"] = "worker.1"
      expect(described_class.run).to be_nil
    end

    it "starts a thread with an initial sleep based on dyno number and interval based on worker count" do
      ENV["WEB_CONCURRENCY"] = "7"
      ENV["DYNO"] = "web.3"
      @refresher = described_class.run
      expect(@refresher).to be_a(described_class)
      expect(@refresher.instance_variable_get(:@initial_sleep)).to eq 180
      expect(@refresher.instance_variable_get(:@interval)).to eq 4800.0 / 7
      expect(@refresher.instance_variable_get(:@thread)).to be_alive
    end

    it "uses PS if DYNO is not set" do
      ENV["WEB_CONCURRENCY"] = "6"
      ENV["PS"] = "web.2"
      @refresher = described_class.run
      expect(@refresher.instance_variable_get(:@initial_sleep)).to eq 120
      expect(@refresher.instance_variable_get(:@interval)).to eq 800.0
    end
  end

  it "uses Puma.stats_hash by default for stats" do
    puma_stats({worker_status: [{pid: 105, index: 0, booted: true, started_at: "2026-11-25T09:00:00Z"}]})
    r = described_class.new(interval: 0)
    expect(r.instance_variable_get(:@initial_sleep)).to eq 0
    expect(Process).to receive(:kill).with(:TERM, 105)
    expect(r.retire_oldest_worker).to eq 105
  end

  describe "#retire_oldest_worker" do
    it "sends SIGTERM to the earliest started booted worker" do
      expect(Process).to receive(:kill).with(:TERM, 102)
      expect(refresher.retire_oldest_worker).to eq 102
    end

    it "returns nil if there are no booted workers" do
      worker_status.each { it[:booted] = false }
      expect(Process).not_to receive(:kill)
      expect(refresher.retire_oldest_worker).to be_nil
    end

    it "returns nil if there is no worker status" do
      refresher = described_class.new(interval: 0, get_stats: -> { {} })
      expect(Process).not_to receive(:kill)
      expect(refresher.retire_oldest_worker).to be_nil
    end

    it "returns nil if the worker has already exited" do
      expect(Process).to receive(:kill).with(:TERM, 102).and_raise(Errno::ESRCH)
      expect(refresher.retire_oldest_worker).to be_nil
    end
  end

  it "#shutdown! works if the thread hasn't been started" do
    expect(refresher.shutdown!).to be_nil
  end

  it "#run_thread retires workers until shutdown" do
    kills = Queue.new
    allow(Process).to receive(:kill).with(:TERM, 102) { kills.push(it) }
    thread = refresher.run_thread
    2.times { expect(kills.pop(timeout: 5)).to eq :TERM }
    expect(refresher.shutdown!).to be_nil
    expect(thread.alive?).to be false
    expect(thread.value).to be true
  end

  it "#run_thread handles unexpected errors" do
    refresher = described_class.new(interval: 0, get_stats: -> { raise "unexpected" })
    expect(refresher.run_thread.value).to be false
  end

  it "#run_thread waits for the initial sleep and then the interval before retiring a worker" do
    allow(Process).to receive(:kill).with(:TERM, 102)
    @refresher = described_class.new(initial_sleep: 0.1, interval: 0.1, get_stats:)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @refresher.run_thread
    first_retire = stats_calls.pop(timeout: 5)
    expect(first_retire - started).to be >= 0.2
    second_retire = stats_calls.pop(timeout: 5)
    expect(second_retire - first_retire).to be >= 0.1
  end

  it "#shutdown! stops the thread during the initial sleep without retiring workers" do
    refresher = described_class.new(initial_sleep: 600, interval: 0, get_stats:)
    expect(Process).not_to receive(:kill)
    thread = refresher.run_thread
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(refresher.shutdown!).to be_nil
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    expect(thread.alive?).to be false
    expect(thread.value).to be true
    expect(stats_calls).to be_empty
  end
end
