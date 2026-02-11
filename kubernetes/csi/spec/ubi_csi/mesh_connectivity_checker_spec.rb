# frozen_string_literal: true

require "logger"
require "spec_helper"

RSpec.describe Csi::MeshConnectivityChecker do
  let(:logger) { Logger.new(File::NULL) }
  let(:node_id) { "worker-1" }
  let(:checker) { described_class.new(logger:, node_id:) }

  describe "#initialize" do
    it "parses external endpoints from ENV" do
      ENV["EXTERNAL_ENDPOINTS"] = "10.0.0.1:443,api.example.com:8080"
      checker_with_endpoints = described_class.new(logger:, node_id:)
      endpoints = checker_with_endpoints.instance_variable_get(:@external_endpoints)
      expect(endpoints).to eq([{host: "10.0.0.1", port: 443}, {host: "api.example.com", port: 8080}])
    ensure
      ENV.delete("EXTERNAL_ENDPOINTS")
    end
  end

  describe "#shutdown!" do
    it "sets shutdown flag, closes queues, and joins threads" do
      thread = instance_double(Thread)
      mtr_thread = instance_double(Thread)
      checker.instance_variable_set(:@thread, thread)
      checker.instance_variable_set(:@mtr_thread, mtr_thread)
      expect(thread).to receive(:join)
      expect(mtr_thread).to receive(:join)

      checker.shutdown!

      expect(checker.instance_variable_get(:@shutdown)).to be(true)
      expect(checker.instance_variable_get(:@queue)).to be_closed
      expect(checker.instance_variable_get(:@mtr_queue)).to be_closed
    end

    it "handles nil threads gracefully" do
      checker.shutdown!

      expect(checker.instance_variable_get(:@shutdown)).to be(true)
      expect(checker.instance_variable_get(:@queue)).to be_closed
      expect(checker.instance_variable_get(:@mtr_queue)).to be_closed
    end
  end

  describe "#start" do
    it "spawns threads and logs startup" do
      expect(checker).to receive(:spawn_connectivity_check_thread)
      expect(checker).to receive(:spawn_mtr_check_thread)
      expect(logger).to receive(:info).with("[MeshConnectivity] Started mesh connectivity checker for node worker-1").and_call_original

      checker.start
    end
  end

  describe "#status_response" do
    it "returns node_id, pod_status, and mtr_results" do
      checker.instance_variable_set(:@pod_status, {
        "ubicsi-nodeplugin-xyz" => {ip: "10.0.0.2", reachable: true, last_check: "2026-01-01T00:00:00Z"}
      })
      checker.instance_variable_set(:@mtr_results, {
        "ubicsi-nodeplugin-xyz" => {ip: "10.0.0.2", output: "HOST: ...", exit_status: 0, last_check: "2026-01-01T00:00:00Z"}
      })

      response = checker.status_response

      expect(response[:node_id]).to eq("worker-1")
      expect(response[:pods]["ubicsi-nodeplugin-xyz"][:reachable]).to be true
      expect(response[:mtr_results]["ubicsi-nodeplugin-xyz"][:output]).to eq("HOST: ...")
    end
  end

  describe "#spawn_connectivity_check_thread" do
    let(:client) { instance_double(Csi::KubernetesClient) }
    let(:nodeplugin_pods) { [{"name" => "ubicsi-nodeplugin-abc", "ip" => "10.0.0.2", "node" => "worker-2"}] }

    it "runs connectivity check loop until shutdown" do
      expect(Csi::KubernetesClient).to receive(:new).at_least(:once).and_return(client)
      expect(client).to receive(:get_nodeplugin_pods).at_least(:once).and_return(nodeplugin_pods)
      expect(checker).to receive(:check_endpoints).at_least(:once)
      expect(checker).to receive(:write_status_file).at_least(:once)

      thread = checker.spawn_connectivity_check_thread
      sleep(0.1)
      checker.shutdown!
      thread.join(1)
    end
  end

  describe "#check_all_pods_connectivity" do
    let(:client) { instance_double(Csi::KubernetesClient) }
    let(:pods) {
      [
        {"name" => "ubicsi-nodeplugin-abc", "ip" => "10.0.0.1", "node" => "worker-1"},
        {"name" => "ubicsi-nodeplugin-xyz", "ip" => "10.0.0.2", "node" => "worker-2"}
      ]
    }

    it "enqueues mtr when pod connectivity check fails" do
      expect(Csi::KubernetesClient).to receive(:new).and_return(client)
      expect(client).to receive(:get_nodeplugin_pods).and_return(pods)
      expect(checker).to receive(:check_endpoints).with([{host: "10.0.0.2", port: 8080, name: "ubicsi-nodeplugin-xyz"}])
        .and_yield({host: "10.0.0.2", port: 8080, name: "ubicsi-nodeplugin-xyz"}, false, "Connection timed out")
      expect(checker).to receive(:enqueue_mtr).with("ubicsi-nodeplugin-xyz", "10.0.0.2")

      checker.check_all_pods_connectivity
    end

    it "clears mtr result when pod connectivity check succeeds" do
      checker.instance_variable_set(:@mtr_results, {
        "ubicsi-nodeplugin-xyz" => {ip: "10.0.0.2", output: "HOST: ...", exit_status: 0, last_check: "2026-01-01T00:00:00Z"}
      })
      expect(Csi::KubernetesClient).to receive(:new).and_return(client)
      expect(client).to receive(:get_nodeplugin_pods).and_return(pods)
      expect(checker).to receive(:check_endpoints).with([{host: "10.0.0.2", port: 8080, name: "ubicsi-nodeplugin-xyz"}])
        .and_yield({host: "10.0.0.2", port: 8080, name: "ubicsi-nodeplugin-xyz"}, true, nil)

      checker.check_all_pods_connectivity

      expect(checker.instance_variable_get(:@mtr_results).keys).to eq([])
    end

    it "logs error and returns early when client fails" do
      expect(Csi::KubernetesClient).to receive(:new).and_return(client)
      expect(client).to receive(:get_nodeplugin_pods).and_raise(StandardError.new("API error"))
      expect(logger).to receive(:error).with("[MeshConnectivity] Failed to get nodeplugin pods: API error").and_call_original

      expect(checker.check_all_pods_connectivity).to be_nil
    end

    it "skips pods without IP" do
      pods_with_nil_ip = [
        {"name" => "ubicsi-nodeplugin-abc", "ip" => nil, "node" => "worker-2"},
        {"name" => "ubicsi-nodeplugin-xyz", "ip" => "10.0.0.2", "node" => "worker-2"}
      ]
      expect(Csi::KubernetesClient).to receive(:new).and_return(client)
      expect(client).to receive(:get_nodeplugin_pods).and_return(pods_with_nil_ip)
      expect(checker).to receive(:check_endpoints).with([{host: "10.0.0.2", port: 8080, name: "ubicsi-nodeplugin-xyz"}])

      checker.check_all_pods_connectivity
    end

    it "removes stale pods and mtr results that no longer exist in the cluster" do
      checker.instance_variable_set(:@pod_status, {
        "ubicsi-nodeplugin-old" => {ip: "10.0.0.99", reachable: true, last_check: "2026-01-01T00:00:00Z"},
        "ubicsi-nodeplugin-xyz" => {ip: "10.0.0.2", reachable: true, last_check: "2026-01-01T00:00:00Z"}
      })
      checker.instance_variable_set(:@mtr_results, {
        "ubicsi-nodeplugin-old" => {ip: "10.0.0.99", output: "HOST: ...", exit_status: 0, last_check: "2026-01-01T00:00:00Z"},
        "coredns:coredns-abc" => {ip: "10.96.0.5", output: "HOST: ...", exit_status: 0, last_check: "2026-01-01T00:00:00Z"}
      })

      current_pods = [
        {"name" => "ubicsi-nodeplugin-abc", "ip" => "10.0.0.1", "node" => "worker-1"},
        {"name" => "ubicsi-nodeplugin-xyz", "ip" => "10.0.0.2", "node" => "worker-2"}
      ]
      expect(Csi::KubernetesClient).to receive(:new).and_return(client)
      expect(client).to receive(:get_nodeplugin_pods).and_return(current_pods)
      expect(checker).to receive(:check_endpoints).with([{host: "10.0.0.2", port: 8080, name: "ubicsi-nodeplugin-xyz"}])
        .and_yield({host: "10.0.0.2", port: 8080, name: "ubicsi-nodeplugin-xyz"}, true, nil)

      checker.check_all_pods_connectivity

      pod_status = checker.instance_variable_get(:@pod_status)
      expect(pod_status.keys).to eq(["ubicsi-nodeplugin-xyz"])

      mtr_results = checker.instance_variable_get(:@mtr_results)
      expect(mtr_results.keys).to eq(["coredns:coredns-abc"])
    end
  end

  describe "#check_endpoints" do
    let(:target) { {host: "10.0.0.1", port: 443, name: "test-pod"} }

    it "returns early for empty targets" do
      expect(Socket).not_to receive(:getaddrinfo)
      checker.check_endpoints([]) { |_t, _r, _e| }
    end

    it "yields reachable when connection succeeds immediately" do
      expect(Socket).to receive(:getaddrinfo).with("10.0.0.1", 443, nil, :STREAM).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      expect(Socket).to receive(:new).with(2, :STREAM, 0).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock)
      expect(socket).to receive(:close)
      expect(logger).to receive(:debug).with("[MeshConnectivity] Pod test-pod (10.0.0.1:443) reachable").and_call_original

      results = []
      checker.check_endpoints([target]) { |t, r, e| results << {target: t, reachable: r, error: e} }

      expect(results.first[:reachable]).to be true
      expect(results.first[:error]).to be_nil
    end

    it "yields unreachable when DNS lookup fails" do
      expect(Socket).to receive(:getaddrinfo).and_raise(SocketError.new("getaddrinfo failed"))
      expect(logger).to receive(:warn).with(/\[MeshConnectivity\] Pod test-pod \(10\.0\.0\.1:443\) unreachable: SocketError: getaddrinfo failed/).and_call_original

      results = []
      checker.check_endpoints([target]) { |t, r, e| results << {target: t, reachable: r, error: e} }

      expect(results.first[:reachable]).to be false
      expect(results.first[:error]).to start_with("SocketError: getaddrinfo failed\n")
    end

    it "yields reachable for pending connection that succeeds after IO.select" do
      expect(Socket).to receive(:getaddrinfo).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      remote_addr = instance_double(Addrinfo)
      expect(Socket).to receive(:new).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock).and_return(:wait_writable)
      expect(IO).to receive(:select).and_return([nil, [socket], nil])
      expect(socket).to receive(:remote_address).and_return(remote_addr)
      expect(socket).to receive(:connect_nonblock).with(remote_addr).and_raise(Errno::EISCONN)
      expect(socket).to receive(:close)
      expect(logger).to receive(:debug).with("[MeshConnectivity] Pod test-pod (10.0.0.1:443) reachable").and_call_original

      results = []
      checker.check_endpoints([target]) { |t, r, e| results << {target: t, reachable: r, error: e} }

      expect(results.first[:reachable]).to be true
    end

    it "yields unreachable when connection fails after IO.select" do
      expect(Socket).to receive(:getaddrinfo).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      remote_addr = instance_double(Addrinfo)
      expect(Socket).to receive(:new).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock).and_return(:wait_writable)
      expect(IO).to receive(:select).and_return([nil, [socket], nil])
      expect(socket).to receive(:remote_address).and_return(remote_addr)
      expect(socket).to receive(:connect_nonblock).with(remote_addr).and_raise(Errno::ECONNREFUSED)
      expect(socket).to receive(:close)
      expect(logger).to receive(:warn).with(/\[MeshConnectivity\] Pod test-pod \(10\.0\.0\.1:443\) unreachable: Errno::ECONNREFUSED/).and_call_original

      results = []
      checker.check_endpoints([target]) { |t, r, e| results << {target: t, reachable: r, error: e} }

      expect(results.first[:reachable]).to be false
      expect(results.first[:error]).to start_with("Errno::ECONNREFUSED:")
    end

    it "yields unreachable when IO.select returns nil" do
      expect(Socket).to receive(:getaddrinfo).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      expect(Socket).to receive(:new).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock).and_return(:wait_writable)
      expect(IO).to receive(:select).and_return(nil)
      expect(socket).to receive(:close)
      expect(logger).to receive(:warn).with("[MeshConnectivity] Pod test-pod (10.0.0.1:443) unreachable: Connection timed out").and_call_original

      results = []
      checker.check_endpoints([target]) { |t, r, e| results << {target: t, reachable: r, error: e} }

      expect(results.first[:reachable]).to be false
      expect(results.first[:error]).to eq("Connection timed out")
    end

    it "yields unreachable when deadline exceeded before IO.select" do
      expect(Socket).to receive(:getaddrinfo).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      expect(Socket).to receive(:new).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock).and_return(:wait_writable)

      stub_const("Csi::MeshConnectivityChecker::CONNECTION_TIMEOUT", -1)
      expect(socket).to receive(:close)
      expect(logger).to receive(:warn).with("[MeshConnectivity] Pod test-pod (10.0.0.1:443) unreachable: Connection timed out").and_call_original

      results = []
      checker.check_endpoints([target]) { |t, r, e| results << {target: t, reachable: r, error: e} }

      expect(results.first[:error]).to eq("Connection timed out")
    end

    it "yields reachable for pending connection where connect_nonblock succeeds without EISCONN" do
      expect(Socket).to receive(:getaddrinfo).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      remote_addr = instance_double(Addrinfo)
      expect(Socket).to receive(:new).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock).and_return(:wait_writable)
      expect(IO).to receive(:select).and_return([nil, [socket], nil])
      expect(socket).to receive(:remote_address).and_return(remote_addr)
      expect(socket).to receive(:connect_nonblock).with(remote_addr).and_return(0)
      expect(socket).to receive(:close)
      expect(logger).to receive(:debug).with("[MeshConnectivity] Pod test-pod (10.0.0.1:443) reachable").and_call_original

      results = []
      checker.check_endpoints([target]) { |t, r, e| results << {target: t, reachable: r, error: e} }

      expect(results.first[:reachable]).to be true
    end
  end

  describe "#update_pod_status" do
    it "updates the pod status hash" do
      freeze_time = Time.utc(2026, 1, 1, 12, 0, 0)
      expect(Time).to receive(:now).and_return(freeze_time)

      checker.update_pod_status("ubicsi-nodeplugin-xyz", "10.0.0.2", true)

      status = checker.instance_variable_get(:@pod_status)["ubicsi-nodeplugin-xyz"]
      expect(status[:ip]).to eq("10.0.0.2")
      expect(status[:reachable]).to be true
      expect(status[:error]).to be_nil
      expect(status[:last_check]).to eq("2026-01-01T12:00:00Z")
    end

    it "stores error when provided" do
      freeze_time = Time.utc(2026, 1, 1, 12, 0, 0)
      expect(Time).to receive(:now).and_return(freeze_time)

      checker.update_pod_status("ubicsi-nodeplugin-xyz", "10.0.0.2", false, error: "Errno::ECONNREFUSED")

      status = checker.instance_variable_get(:@pod_status)["ubicsi-nodeplugin-xyz"]
      expect(status[:ip]).to eq("10.0.0.2")
      expect(status[:reachable]).to be false
      expect(status[:error]).to eq("Errno::ECONNREFUSED")
      expect(status[:last_check]).to eq("2026-01-01T12:00:00Z")
    end
  end

  describe "#write_status_file" do
    it "writes status to file atomically" do
      Dir.mktmpdir do |dir|
        status_file_path = File.join(dir, "mesh_status.json")
        stub_const("Csi::MeshConnectivityChecker::STATUS_FILE_PATH", status_file_path)

        checker.instance_variable_set(:@pod_status, {
          "ubicsi-nodeplugin-xyz" => {ip: "10.0.0.2", reachable: true, last_check: "2026-01-01T00:00:00Z"}
        })

        checker.write_status_file

        expect(File.exist?(status_file_path)).to be true
        content = JSON.parse(File.read(status_file_path))
        expect(content["node_id"]).to eq("worker-1")
        expect(content["pods"]["ubicsi-nodeplugin-xyz"]["reachable"]).to be true
        expect(File.stat(status_file_path).mode & 0o777).to eq(0o644)
      end
    end

    it "logs error when file write fails" do
      stub_const("Csi::MeshConnectivityChecker::STATUS_FILE_PATH", "/nonexistent/path/mesh_status.json")
      expect(logger).to receive(:error).with(/\[MeshConnectivity\] Failed to write status file:/).and_call_original

      checker.write_status_file
    end
  end

  describe "#parse_external_endpoints" do
    it "returns empty array for nil input" do
      expect(checker.parse_external_endpoints(nil)).to eq([])
    end

    it "returns empty array for empty string" do
      expect(checker.parse_external_endpoints("")).to eq([])
    end

    it "returns empty array for whitespace only string" do
      expect(checker.parse_external_endpoints("   ")).to eq([])
    end

    it "parses single endpoint with port" do
      result = checker.parse_external_endpoints("10.0.0.1:443")
      expect(result).to eq([{host: "10.0.0.1", port: 443}])
    end

    it "raises error for endpoint without port" do
      expect { checker.parse_external_endpoints("10.0.0.1") }.to raise_error("Port required in endpoint: 10.0.0.1")
    end

    it "parses multiple endpoints" do
      result = checker.parse_external_endpoints("10.0.0.1:443,api.example.com:8080")
      expect(result).to eq([
        {host: "10.0.0.1", port: 443},
        {host: "api.example.com", port: 8080}
      ])
    end

    it "handles whitespace in endpoints" do
      result = checker.parse_external_endpoints("  10.0.0.1:443 , api.example.com:8080  ")
      expect(result).to eq([
        {host: "10.0.0.1", port: 443},
        {host: "api.example.com", port: 8080}
      ])
    end

    it "skips empty entries" do
      result = checker.parse_external_endpoints("10.0.0.1:443,,api.example.com:8080")
      expect(result).to eq([
        {host: "10.0.0.1", port: 443},
        {host: "api.example.com", port: 8080}
      ])
    end

    it "raises error for invalid port" do
      expect { checker.parse_external_endpoints("10.0.0.1:invalid") }.to raise_error("Invalid port in endpoint: 10.0.0.1:invalid")
    end

    it "raises error for IPv6 address without port" do
      expect { checker.parse_external_endpoints("2001:db8::1") }.to raise_error("Invalid IPv6 address (missing port?): 2001:db8::1")
    end
  end

  describe "#status_response with external endpoints" do
    it "includes external_endpoints and mtr_results in response" do
      checker.instance_variable_set(:@pod_status, {
        "kube-proxy-xyz" => {ip: "10.0.0.2", reachable: true, last_check: "2026-01-01T00:00:00Z"}
      })
      checker.instance_variable_set(:@external_status, {
        "10.0.0.1:443" => {reachable: true, last_check: "2026-01-01T00:00:00Z"}
      })
      checker.instance_variable_set(:@mtr_results, {
        "kube-proxy-xyz" => {ip: "10.0.0.2", output: "HOST: ...", exit_status: 0, last_check: "2026-01-01T00:00:00Z"}
      })

      response = checker.status_response

      expect(response[:node_id]).to eq("worker-1")
      expect(response[:pods]["kube-proxy-xyz"][:reachable]).to be true
      expect(response[:external_endpoints]["10.0.0.1:443"][:reachable]).to be true
      expect(response[:mtr_results]["kube-proxy-xyz"][:output]).to eq("HOST: ...")
    end
  end

  describe "#check_all_external_endpoints" do
    it "checks all external endpoints using check_endpoints" do
      endpoints = [{host: "10.0.0.1", port: 443}, {host: "api.example.com", port: 8080}]
      checker.instance_variable_set(:@external_endpoints, endpoints)

      expect(checker).to receive(:check_endpoints).with([
        {host: "10.0.0.1", port: 443, name: "10.0.0.1:443"},
        {host: "api.example.com", port: 8080, name: "api.example.com:8080"}
      ]).and_yield({host: "10.0.0.1", port: 443, name: "10.0.0.1:443"}, true, nil)

      checker.check_all_external_endpoints

      status = checker.instance_variable_get(:@external_status)["10.0.0.1:443"]
      expect(status[:reachable]).to be true
    end

    it "handles empty endpoints list" do
      checker.instance_variable_set(:@external_endpoints, [])
      expect(checker).not_to receive(:check_endpoints)
      checker.check_all_external_endpoints
    end

    it "enqueues mtr to target when external endpoint fails with connection error" do
      endpoints = [{host: "10.0.0.1", port: 443}]
      checker.instance_variable_set(:@external_endpoints, endpoints)

      expect(checker).to receive(:check_endpoints).and_yield(
        {host: "10.0.0.1", port: 443, name: "10.0.0.1:443"}, false, "Errno::ECONNREFUSED: Connection refused"
      )

      checker.check_all_external_endpoints

      target = checker.instance_variable_get(:@mtr_queue).pop(true)
      expect(target).to eq({name: "10.0.0.1:443", ip: "10.0.0.1"})
    end

    it "enqueues mtr to coredns when external endpoint fails with DNS error" do
      endpoints = [{host: "api.example.com", port: 8080}]
      checker.instance_variable_set(:@external_endpoints, endpoints)

      expect(checker).to receive(:check_endpoints).and_yield(
        {host: "api.example.com", port: 8080, name: "api.example.com:8080"}, false, "SocketError: getaddrinfo failed\nbacktrace..."
      )
      expect(checker).to receive(:enqueue_mtr_for_coredns)

      checker.check_all_external_endpoints
    end

    it "clears mtr and coredns results when external endpoint succeeds" do
      endpoints = [{host: "10.0.0.1", port: 443}]
      checker.instance_variable_set(:@external_endpoints, endpoints)
      checker.instance_variable_set(:@mtr_results, {
        "10.0.0.1:443" => {ip: "10.0.0.1", output: "HOST: ...", exit_status: 0, last_check: "2026-01-01T00:00:00Z"},
        "coredns:coredns-abc" => {ip: "10.96.0.5", output: "HOST: ...", exit_status: 0, last_check: "2026-01-01T00:00:00Z"}
      })

      expect(checker).to receive(:check_endpoints).and_yield(
        {host: "10.0.0.1", port: 443, name: "10.0.0.1:443"}, true, nil
      )

      checker.check_all_external_endpoints

      mtr_results = checker.instance_variable_get(:@mtr_results)
      expect(mtr_results).to be_empty
    end
  end

  describe "#spawn_mtr_check_thread" do
    it "processes targets from queue until shutdown" do
      target = {name: "ubicsi-nodeplugin-xyz", ip: "10.0.0.2"}
      expect(checker).to receive(:run_mtr_for_target).with(target)
      expect(checker).to receive(:write_status_file).and_wrap_original do |original|
        original.call
        checker.shutdown!
      end

      thread = checker.spawn_mtr_check_thread
      checker.instance_variable_get(:@mtr_queue) << target
      thread.join(1)
      expect(thread).not_to be_alive
    end

    it "exits when queue is closed" do
      thread = checker.spawn_mtr_check_thread
      checker.shutdown!
      thread.join(1)
      expect(thread).not_to be_alive
    end

    it "breaks when queue returns nil" do
      thread = checker.spawn_mtr_check_thread
      checker.instance_variable_get(:@mtr_queue).close
      thread.join(1)
      expect(thread).not_to be_alive
    end
  end

  describe "#enqueue_mtr" do
    it "enqueues target to mtr queue" do
      checker.enqueue_mtr("ubicsi-nodeplugin-xyz", "10.0.0.2")

      target = checker.instance_variable_get(:@mtr_queue).pop(true)
      expect(target).to eq({name: "ubicsi-nodeplugin-xyz", ip: "10.0.0.2"})
    end

    it "handles closed queue gracefully" do
      checker.instance_variable_get(:@mtr_queue).close
      expect { checker.enqueue_mtr("ubicsi-nodeplugin-xyz", "10.0.0.2") }.not_to raise_error
    end
  end

  describe "#enqueue_mtr_for_coredns" do
    let(:client) { instance_double(Csi::KubernetesClient) }

    it "enqueues mtr for each CoreDNS pod" do
      pods = [
        {"name" => "coredns-abc", "ip" => "10.96.0.5"},
        {"name" => "coredns-xyz", "ip" => "10.96.0.6"}
      ]
      expect(Csi::KubernetesClient).to receive(:new).with(req_id: "mtr-coredns", logger:, log_level: :debug).and_return(client)
      expect(client).to receive(:get_coredns_pods).and_return(pods)

      checker.enqueue_mtr_for_coredns

      queue = checker.instance_variable_get(:@mtr_queue)
      targets = []
      targets << queue.pop(true) until queue.empty?
      expect(targets).to eq([
        {name: "coredns:coredns-abc", ip: "10.96.0.5"},
        {name: "coredns:coredns-xyz", ip: "10.96.0.6"}
      ])
    end

    it "skips CoreDNS pods without IP" do
      pods = [
        {"name" => "coredns-abc", "ip" => nil},
        {"name" => "coredns-xyz", "ip" => "10.96.0.6"}
      ]
      expect(Csi::KubernetesClient).to receive(:new).and_return(client)
      expect(client).to receive(:get_coredns_pods).and_return(pods)

      checker.enqueue_mtr_for_coredns

      queue = checker.instance_variable_get(:@mtr_queue)
      targets = []
      targets << queue.pop(true) until queue.empty?
      expect(targets).to eq([{name: "coredns:coredns-xyz", ip: "10.96.0.6"}])
    end

    it "logs error when fetching CoreDNS pods fails" do
      expect(Csi::KubernetesClient).to receive(:new).and_return(client)
      expect(client).to receive(:get_coredns_pods).and_raise(StandardError.new("API error"))
      expect(logger).to receive(:error).with("[MeshConnectivity] Failed to get CoreDNS pods for MTR: API error").and_call_original

      checker.enqueue_mtr_for_coredns
    end
  end

  describe "#run_mtr_for_target" do
    let(:target) { {name: "ubicsi-nodeplugin-xyz", ip: "10.0.0.2"} }
    let(:process_status) { instance_double(Process::Status, exitstatus: 0) }

    it "runs mtr command and stores output" do
      freeze_time = Time.utc(2026, 1, 1, 12, 0, 0)
      expect(Time).to receive(:now).and_return(freeze_time)
      mtr_output = "HOST: worker-1  Loss%   Snt   Last   Avg  Best  Wrst StDev\n  1.|-- 10.0.0.2  0.0%     2   0.5   0.5   0.4   0.6   0.1"
      expect(checker).to receive(:run_cmd).with("timeout", "15", "mtr", "-n", "-c2", "-rw", "10.0.0.2", req_id: "mtr-check").and_return([mtr_output, process_status])
      expect(logger).to receive(:debug).with("[MeshConnectivity] MTR completed for ubicsi-nodeplugin-xyz (10.0.0.2)").and_call_original

      checker.run_mtr_for_target(target)

      result = checker.instance_variable_get(:@mtr_results)["ubicsi-nodeplugin-xyz"]
      expect(result[:ip]).to eq("10.0.0.2")
      expect(result[:output]).to eq(mtr_output)
      expect(result[:exit_status]).to eq(0)
      expect(result[:last_check]).to eq("2026-01-01T12:00:00Z")
    end

    it "stores non-zero exit status" do
      expect(Time).to receive(:now).and_return(Time.utc(2026, 1, 1))
      failed_status = instance_double(Process::Status, exitstatus: 1)
      expect(checker).to receive(:run_cmd).with("timeout", "15", "mtr", "-n", "-c2", "-rw", "10.0.0.2", req_id: "mtr-check").and_return(["error output", failed_status])

      checker.run_mtr_for_target(target)

      result = checker.instance_variable_get(:@mtr_results)["ubicsi-nodeplugin-xyz"]
      expect(result[:exit_status]).to eq(1)
    end

    it "logs error when run_cmd raises" do
      expect(checker).to receive(:run_cmd).and_raise(StandardError.new("command not found"))
      expect(logger).to receive(:error).with("[MeshConnectivity] MTR failed for ubicsi-nodeplugin-xyz (10.0.0.2): command not found").and_call_original

      checker.run_mtr_for_target(target)
    end
  end
end
