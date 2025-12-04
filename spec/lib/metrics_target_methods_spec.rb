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
        allow(test_instance).to receive(:scrape_endpoints).and_return([])
        allow(Clog).to receive(:emit).and_call_original
      end

      it "does not call import_prometheus or mark_pending_scrapes_as_done" do
        expect(mock_tsdb_client).not_to receive(:import_prometheus)
        expect(test_instance).not_to receive(:mark_pending_scrapes_as_done)

        test_instance.export_metrics(session: session, tsdb_client: mock_tsdb_client)
      end
    end

    context "when scrape results exist" do
      let(:time) { Time.now }
      let(:scrape_result_a) { VictoriaMetrics::Client::Scrape.new(time: time - 10, samples: "metric1{} 1") }
      let(:scrape_result_b) { VictoriaMetrics::Client::Scrape.new(time: time, samples: "metric2{} 2") }
      let(:scrape_results) { [scrape_result_a, scrape_result_b] }

      before do
        allow(test_instance).to receive(:scrape_endpoints).and_return(scrape_results)
        allow(Clog).to receive(:emit).and_call_original
        allow(test_instance).to receive(:mark_pending_scrapes_as_done)
      end

      it "does not call import_prometheus or mark_pending_scrapes_as_done if tsdb_client is nil" do
        expect(mock_tsdb_client).not_to receive(:import_prometheus)
        expect(test_instance).not_to receive(:mark_pending_scrapes_as_done)
        test_instance.export_metrics(session: session, tsdb_client: nil)
      end

      it "imports all scrapes and marks them as done" do
        expect(mock_tsdb_client).to receive(:import_prometheus).with(scrape_result_a, {foo: "bar"})
        expect(mock_tsdb_client).to receive(:import_prometheus).with(scrape_result_b, {foo: "bar"})
        expect(test_instance).to receive(:mark_pending_scrapes_as_done).with(session, time)

        test_instance.export_metrics(session: session, tsdb_client: mock_tsdb_client)
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
      allow(test_instance).to receive(:metrics_config).and_return({metrics_dir: "/path with spaces"})
      expect(test_instance.send(:metrics_dir)).to eq("/path with spaces")
    end
  end
end
