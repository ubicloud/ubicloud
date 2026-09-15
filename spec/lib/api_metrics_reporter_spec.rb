# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ApiMetricsReporter do
  let(:reporter) { described_class.new(interval: @interval || 15) }

  after do
    expect(reporter.shutdown!).to be_nil
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
    expect(Clog).to receive(:emit).with("api metrics reporter thread exiting due to unexpected error", Hash).and_call_original
    thread = reporter.run_thread
    expect(thread.join(1).value).to be false
  end

  it "#run reports once per tick until shutdown" do
    @interval = 0
    count = 0
    expect(reporter).to receive(:report).twice do
      count += 1
      reporter.shutdown_queue.push(true) if count == 2
    end
    reporter.run
  end

  it "#report skips reporting when VictoriaMetrics is not configured" do
    expect(Clog).to receive(:emit).with("api metrics report skipped because VictoriaMetrics is not configured").and_call_original
    expect(reporter.report).to be_nil
  end

  it "#report imports the rendered registry with an instance label" do
    expect(Config).to receive(:victoria_metrics_endpoint_override).twice.and_return("https://vm.example")
    client = instance_double(VictoriaMetrics::Client)
    expect(VictoriaMetrics::Client).to receive(:new).with(endpoint: "https://vm.example").and_return(client)
    expect(client).to receive(:import_prometheus) do |scrape, extra_labels|
      expect(scrape.time).to be_a Time
      expect(scrape.samples).to include "http_request_duration_seconds"
      expect(extra_labels).to eq({instance: Socket.gethostname})
    end
    reporter.report
  end

  it "#report uses the instance keyword argument for the instance label" do
    custom = described_class.new(instance: "spec-instance")
    expect(Config).to receive(:victoria_metrics_endpoint_override).twice.and_return("https://vm.example")
    client = instance_double(VictoriaMetrics::Client)
    expect(VictoriaMetrics::Client).to receive(:new).with(endpoint: "https://vm.example").and_return(client)
    expect(client).to receive(:import_prometheus) do |_scrape, extra_labels|
      expect(extra_labels).to eq({instance: "spec-instance"})
    end
    custom.report
  ensure
    custom.shutdown!
  end

  it "#report emits and continues when the client fails" do
    expect(Config).to receive(:victoria_metrics_endpoint_override).twice.and_return("https://vm.example")
    client = instance_double(VictoriaMetrics::Client)
    expect(VictoriaMetrics::Client).to receive(:new).with(endpoint: "https://vm.example").and_return(client)
    expect(client).to receive(:import_prometheus).and_raise(VictoriaMetrics::ClientError.new("boom"))
    expect(Clog).to receive(:emit).with("api metrics report failed", Hash).and_call_original
    expect(reporter.report).to be_nil
  end

  it "#report emits and continues when the client database lookup fails" do
    expect(VictoriaMetricsResource).to receive(:client_for_project).and_raise(Sequel::DatabaseConnectionError)
    expect(Clog).to receive(:emit).with("api metrics report failed", Hash).and_call_original
    expect(reporter.report).to be_nil
  end
end
