# frozen_string_literal: true

require "logger"
require "spec_helper"

RSpec.describe Csi::MeshConnectivityChecker do
  let(:logger) { Logger.new(File::NULL) }
  let(:node_id) { "worker-1" }
  let(:checker) { described_class.new(logger:, node_id:) }

  describe "#shutdown!" do
    it "sets shutdown flag, closes queue, and joins thread" do
      thread = instance_double(Thread)
      checker.instance_variable_set(:@thread, thread)
      expect(thread).to receive(:join)

      checker.shutdown!

      expect(checker.instance_variable_get(:@shutdown)).to be(true)
      expect(checker.instance_variable_get(:@queue)).to be_closed
    end

    it "handles nil thread gracefully" do
      checker.shutdown!

      expect(checker.instance_variable_get(:@shutdown)).to be(true)
      expect(checker.instance_variable_get(:@queue)).to be_closed
    end
  end

  describe "#start" do
    it "spawns thread and logs startup" do
      expect(checker).to receive(:spawn_connectivity_check_thread)
      expect(logger).to receive(:info).with("[MeshConnectivity] Started mesh connectivity checker for node worker-1").and_call_original

      checker.start
    end
  end

  describe "#spawn_connectivity_check_thread" do
    let(:client) { instance_double(Csi::KubernetesClient) }
    let(:nodeplugin_pods) { [{"name" => "ubicsi-nodeplugin-abc", "ip" => "10.0.0.2", "node" => "worker-2"}] }

    it "runs connectivity check loop until shutdown" do
      expect(Csi::KubernetesClient).to receive(:new).at_least(:once).and_return(client)
      expect(client).to receive(:get_nodeplugin_pods).at_least(:once).and_return(nodeplugin_pods)
      expect(checker).to receive(:check_endpoints).at_least(:once)

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

    it "fetches pods and builds targets, skipping same node" do
      expect(Csi::KubernetesClient).to receive(:new).and_return(client)
      expect(client).to receive(:get_nodeplugin_pods).and_return(pods)
      expect(logger).to receive(:debug).with("[MeshConnectivity] Found 2 nodeplugin pods").and_call_original
      expect(checker).to receive(:check_endpoints).with([{host: "10.0.0.2", port: 8080, label: "Pod ubicsi-nodeplugin-xyz"}])

      checker.check_all_pods_connectivity
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
      expect(checker).to receive(:check_endpoints).with([{host: "10.0.0.2", port: 8080, label: "Pod ubicsi-nodeplugin-xyz"}])

      checker.check_all_pods_connectivity
    end
  end

  describe "#check_endpoints" do
    let(:target) { {host: "10.0.0.1", port: 443, label: "Test endpoint"} }

    it "returns early for empty targets" do
      expect(Socket).not_to receive(:getaddrinfo)
      checker.check_endpoints([])
    end

    it "logs reachable when connection succeeds immediately" do
      expect(Socket).to receive(:getaddrinfo).with("10.0.0.1", 443, nil, :STREAM).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      expect(Socket).to receive(:new).with(2, :STREAM, 0).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock)
      expect(socket).to receive(:close)
      expect(logger).to receive(:debug).with("[MeshConnectivity] Test endpoint (10.0.0.1:443) reachable").and_call_original

      checker.check_endpoints([target])
    end

    it "logs unreachable when DNS lookup fails" do
      expect(Socket).to receive(:getaddrinfo).and_raise(SocketError.new("getaddrinfo failed"))
      expect(logger).to receive(:warn).with("[MeshConnectivity] Test endpoint (10.0.0.1:443) unreachable: SocketError: getaddrinfo failed").and_call_original

      checker.check_endpoints([target])
    end

    it "handles pending connection that succeeds after IO.select" do
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
      expect(logger).to receive(:debug).with("[MeshConnectivity] Test endpoint (10.0.0.1:443) reachable").and_call_original

      checker.check_endpoints([target])
    end

    it "logs unreachable when connection fails after IO.select" do
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
      expect(logger).to receive(:warn).with(/\[MeshConnectivity\] Test endpoint \(10\.0\.0\.1:443\) unreachable: Errno::ECONNREFUSED/).and_call_original

      checker.check_endpoints([target])
    end

    it "handles timeout when IO.select returns nil" do
      expect(Socket).to receive(:getaddrinfo).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      expect(Socket).to receive(:new).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock).and_return(:wait_writable)
      expect(IO).to receive(:select).and_return(nil)
      expect(socket).to receive(:close)
      expect(logger).to receive(:warn).with("[MeshConnectivity] Test endpoint (10.0.0.1:443) unreachable: Connection timed out").and_call_original

      checker.check_endpoints([target])
    end

    it "handles deadline exceeded before IO.select" do
      expect(Socket).to receive(:getaddrinfo).and_return([
        ["AF_INET", 443, "10.0.0.1", "10.0.0.1", 2, 1, 6]
      ])
      socket = instance_double(Socket)
      expect(Socket).to receive(:new).and_return(socket)
      expect(socket).to receive(:setsockopt)
      expect(socket).to receive(:connect_nonblock).and_return(:wait_writable)

      # Simulate deadline already passed
      stub_const("Csi::MeshConnectivityChecker::CONNECTION_TIMEOUT", -1)
      expect(socket).to receive(:close)
      expect(logger).to receive(:warn).with("[MeshConnectivity] Test endpoint (10.0.0.1:443) unreachable: Connection timed out").and_call_original

      checker.check_endpoints([target])
    end

    it "handles pending connection where connect_nonblock succeeds without EISCONN" do
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
      expect(logger).to receive(:debug).with("[MeshConnectivity] Test endpoint (10.0.0.1:443) reachable").and_call_original

      checker.check_endpoints([target])
    end
  end
end
