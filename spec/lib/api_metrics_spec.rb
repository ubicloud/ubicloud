# frozen_string_literal: true

require_relative "../spec_helper"
require "tmpdir"

RSpec.describe ApiMetrics do
  def with_env(values)
    originals = values.to_h { |key, value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  # A fresh, unfrozen copy of the module, so the load-time initialize can be
  # re-run against a temporary store without mutating the global registry.
  def fresh_metrics
    described_class.clone(freeze: false)
  end

  it "uses a file-backed store and clears stale files at boot in the forking web process" do
    original_store = Prometheus::Client.config.data_store
    Dir.mktmpdir do |dir|
      stale_file = File.join(dir, "stale___test.bin")
      File.write(stale_file, "stale")
      metrics = fresh_metrics
      with_env("WEB_CONCURRENCY" => "2", "PROCESS_TYPE" => "web") { metrics.send(:initialize, store_dir: dir) }
      expect(File.exist?(stale_file)).to be false
      expect(Prometheus::Client.config.data_store).to be_a Prometheus::Client::DataStores::DirectFileStore
      metrics.observe(handler: "/spec/store", method: "GET", code: "200", duration: 0.01)
      expect(metrics.render).to include 'http_request_duration_seconds_count{code="200",handler="/spec/store",method="GET"} 1.0'
    end
  ensure
    Prometheus::Client.config.data_store = original_store
  end

  it "keeps the default store outside the web process" do
    original_store = Prometheus::Client.config.data_store
    Dir.mktmpdir do |dir|
      with_env("WEB_CONCURRENCY" => "2", "PROCESS_TYPE" => "respirate") { fresh_metrics.send(:initialize, store_dir: dir) }
      expect(Prometheus::Client.config.data_store).to be original_store
    end
  end

  it "keeps the default store when puma is not forking" do
    original_store = Prometheus::Client.config.data_store
    Dir.mktmpdir do |dir|
      with_env("WEB_CONCURRENCY" => nil, "PROCESS_TYPE" => "web") { fresh_metrics.send(:initialize, store_dir: dir) }
      expect(Prometheus::Client.config.data_store).to be original_store
    end
  end
end
