# spec/lib/metrics_target_methods_spec.rb
# frozen_string_literal: true

require "spec_helper"
require "metrics_target_methods"

class TestClass
  include MetricsTargetMethods
end

RSpec.describe MetricsTargetMethods do
  let(:test_instance) { TestClass.new }
  let(:mock_ssh_session) { Net::SSH::Connection::Session.allocate }
  let(:session) { {ssh_session: mock_ssh_session} }
  let(:mock_tsdb_client) { instance_double(VictoriaMetrics::Client) }
  let(:metrics_dir) { "/home/ubi/metrics" }

  describe "#metrics_config" do
    it "returns the default configuration" do
      config = test_instance.metrics_config
      expect(config).to be_a(Hash)
      expect(config[:endpoints]).to eq([])
      expect(config[:max_file_retention]).to eq(120)
      expect(config[:interval]).to eq("15s")
      expect(config[:additional_labels]).to eq({foo: "bar"})
      expect(config[:metrics_dir]).to eq("/home/ubi/metrics")
    end
  end

  describe "#export_metrics" do
    context "when scrape results are empty" do
      before do
        expect(mock_ssh_session).to receive(:_exec!).with(/ls.*done/).and_return("")
      end

      it "does not call import_prometheus or mark_pending_scrapes_as_done" do
        expect(mock_tsdb_client).not_to receive(:import_prometheus)
        expect(mock_ssh_session).not_to receive(:_exec!).with(/xargs.*rm/)

        test_instance.export_metrics(session:, tsdb_client: mock_tsdb_client)
      end
    end

    context "when scrape results exist" do
      let(:time_a) { Time.new(2023, 1, 1, 12, 0, 0) }
      let(:time_b) { Time.new(2023, 1, 1, 12, 15, 0) }

      def stub_scrape_ssh_expectations
        expect(mock_ssh_session).to receive(:_exec!).with(/ls.*done/).and_return("2023-01-01T12-00-00-000000000.prom\n2023-01-01T12-15-00-000000000.prom")
        expect(mock_ssh_session).to receive(:_exec!).with(/cat.*done/, status: anything) do |_, options|
          options[:status][:exit_code] = 0
          "metric1{} 1"
        end
        expect(mock_ssh_session).to receive(:_exec!).with(/cat.*done/, status: anything) do |_, options|
          options[:status][:exit_code] = 0
          "metric2{} 2"
        end
      end

      it "does not call import_prometheus if tsdb_client is nil" do
        stub_scrape_ssh_expectations
        expect(mock_tsdb_client).not_to receive(:import_prometheus)
        expect(mock_ssh_session).not_to receive(:_exec!).with(/xargs.*rm/)
        expect(Clog).to receive(:emit).with("VictoriaMetrics server is not configured.")
        test_instance.export_metrics(session:, tsdb_client: nil)
      end

      it "imports all scrapes and marks them as done" do
        stub_scrape_ssh_expectations
        expect(mock_tsdb_client).to receive(:import_prometheus) do |scrape, labels|
          expect(scrape.time).to eq(time_a)
          expect(scrape.samples).to eq("metric1{} 1")
          expect(labels).to eq({foo: "bar"})
        end
        expect(mock_tsdb_client).to receive(:import_prometheus) do |scrape, labels|
          expect(scrape.time).to eq(time_b)
          expect(scrape.samples).to eq("metric2{} 2")
          expect(labels).to eq({foo: "bar"})
        end
        expect(mock_ssh_session).to receive(:_exec!).with(/xargs.*rm/)

        test_instance.export_metrics(session:, tsdb_client: mock_tsdb_client)
      end
    end
  end

  describe "#scrape_endpoints" do
    let(:file_list) { "2023-01-01T12-00-00-000000000.prom\n2023-01-01T12-15-00-000000000.prom" }
    let(:file_content) { "metric{} 1" }
    let(:status_hash) { {exit_code: 0} }

    before do
      allow(mock_ssh_session).to receive(:_exec!).with(/ls.*done/).and_return(file_list)
      allow(mock_ssh_session).to receive(:_exec!).with(/cat.*done/, status: anything) do |_, options|
        options[:status][:exit_code] = status_hash[:exit_code]
        file_content
      end
    end

    context "when files can be read successfully" do
      it "returns the expected scrapes" do
        results = test_instance.scrape_endpoints(session)

        expect(results.length).to eq(2)
        expect(results[0]).to be_a(VictoriaMetrics::Client::Scrape)
        expect(results[0].samples).to eq(file_content)
        expect(results[1]).to be_a(VictoriaMetrics::Client::Scrape)
        expect(results[1].samples).to eq(file_content)
      end
    end

    context "when files cannot be read" do
      let(:status_hash) { {exit_code: 1} }

      it "filters out failed scrapes" do
        results = test_instance.scrape_endpoints(session)
        expect(results).to be_empty
      end
    end
  end

  describe "#mark_pending_scrapes_as_done" do
    let(:time) { Time.new(2023, 1, 1, 12, 0, 0) }
    let(:time_marker) { "2023-01-01T12-00-00-000000000" }

    it "executes the correct command to move files" do
      expect(mock_ssh_session).to receive(:_exec!).with("ls /home/ubi/metrics/done | sort | awk \\$0\\ \\<\\=\\ \\\"2023-01-01T12-00-00-000000000\\\" | xargs -I{} rm /home/ubi/metrics/done/{}")

      test_instance.mark_pending_scrapes_as_done(session, time)
    end
  end

  describe "#metrics_dir" do
    it "returns the unescaped metrics directory path" do
      test_with_custom_config = Class.new {
        include MetricsTargetMethods

        def metrics_config
          {metrics_dir: "/path with spaces"}
        end
      }.new
      expect(test_with_custom_config.send(:metrics_dir)).to eq("/path with spaces")
    end
  end
end
