# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ConnectionCheckoutTelemetry do
  let(:cct) { described_class.new(db: Sequel.mock, key: "test", check_every: 2, report_every: @report_every || -1) }

  after do
    expect(cct.shutdown!).to be_nil
  end

  it "#shutdown! works if the thread hasn't been started" do
    expect(cct.shutdown!).to be_nil
  end

  it "#shutdown! works if the thread has been started" do
    thread = cct.setup_and_run_thread
    expect(cct.shutdown!).to be_nil
    expect(thread.alive?).to be false
    expect(thread.value).to be true
  end

  it "#setup_and_run_thread emits if run method fails" do
    expect(cct).to receive(:run).and_raise(RuntimeError)
    expect(Clog).to receive(:emit).with("test failure", Hash)
    thread = cct.setup_and_run_thread
    expect(thread.join(1).value).to be false
  end

  it "#run does not emit connection checkout telemetry if there hasn't been enough reports" do
    expect(Clog).not_to receive(:emit)
    cct.queue.push(:immediately_available)
    cct.queue.push(nil)
    cct.run
  end

  it "#run does not emit connection checkout telemetry if there hasn't been enough time" do
    @report_every = 10
    expect(Clog).not_to receive(:emit)
    cct.queue.push(:immediately_available)
    cct.queue.push(:not_immediately_available)
    cct.queue.push(nil)
    cct.run
  end

  it "#run emits connection checkout telemetry" do
    expect(Clog).to receive(:emit) do |msg, hash|
      expect(msg).to eq "test"
      data = hash["test"]
      expect(data).to eq({
        "0_30_ms" => 0.0,
        "30_100_ms" => 0.0,
        "100_300_ms" => 0.0,
        "300_1000_ms" => 0.0,
        "1_3_s" => 0.0,
        "immediate" => 50.0,
        "over_3_s" => 0.0,
        "requests" => 2,
        "pool_size" => 1
      })
    end
    cct.queue.push(:immediately_available)
    cct.queue.push(:not_immediately_available)
    cct.queue.push(nil)
    cct.run
  end

  it "#run checks to emit every check_every events" do
    expect(Clog).to receive(:emit).twice
    cct.queue.push(:not_immediately_available)
    cct.queue.push(:new_connection)
    cct.queue.push(:not_immediately_available)
    cct.queue.push(:new_connection)
    cct.queue.push(nil)
    cct.run
  end

  it "#run considers new connections as immediates" do
    expect(Clog).to receive(:emit) do |_, hash|
      expect(hash["test"]["immediate"]).to eq 100.0
    end
    cct.queue.push(:not_immediately_available)
    cct.queue.push(:new_connection)
    cct.queue.push(nil)
    cct.run
  end

  it "#run handles wait times for connections" do
    expect(Clog).to receive(:emit) do |_, hash|
      data = hash["test"]
      expect(data["over_3_s"]).to eq 50.0
      expect(data["1_3_s"]).to eq 50.0
    end
    cct.queue.push(4)
    cct.queue.push(2)
    cct.queue.push(nil)
    cct.run

    expect(Clog).to receive(:emit) do |_, hash|
      data = hash["test"]
      expect(data["300_1000_ms"]).to eq 50.0
      expect(data["100_300_ms"]).to eq 50.0
    end
    cct.queue.push(0.4)
    cct.queue.push(0.2)
    cct.queue.push(nil)
    cct.run

    expect(Clog).to receive(:emit) do |_, hash|
      data = hash["test"]
      expect(data["30_100_ms"]).to eq 50.0
      expect(data["0_30_ms"]).to eq 50.0
    end
    cct.queue.push(0.04)
    cct.queue.push(0.02)
    cct.queue.push(nil)
    cct.run
  end
end
