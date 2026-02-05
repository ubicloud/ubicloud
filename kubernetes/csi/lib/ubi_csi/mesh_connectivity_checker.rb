# frozen_string_literal: true

require "socket"
require "json"
require "tempfile"
require "fileutils"
require_relative "kubernetes_client"

module Csi
  class MeshConnectivityChecker
    CONNECTIVITY_CHECK_INTERVAL = 30
    CONNECTION_TIMEOUT = 5
    REGISTRAR_HEALTHZ_PORT = 8080
    STATUS_FILE_PATH = "/var/lib/ubicsi/mesh_status.json"

    def initialize(logger:, node_id:)
      @logger = logger
      @node_id = node_id
      @queue = Queue.new
      @shutdown = false
      @pod_status = {}
      @external_endpoints = parse_external_endpoints(ENV["EXTERNAL_ENDPOINTS"])
      @external_status = {}
      @mutex = Mutex.new
    end

    def shutdown!
      @shutdown = true
      @queue.close
      @thread&.join
    end

    def parse_external_endpoints(env_value)
      return [] if env_value.nil? || env_value.strip.empty?
      env_value.split(",").filter_map do |endpoint|
        endpoint = endpoint.strip
        next if endpoint.empty?
        # Use rpartition to split on the LAST ":" which handles both IPv4 and IPv6:
        #   "example.com:443"    -> ["example.com", ":", "443"]
        #   "10.0.0.1:8080"      -> ["10.0.0.1", ":", "8080"]
        #   "2001:db8::1:443"    -> ["2001:db8::1", ":", "443"] (IPv6 with port)
        parts = endpoint.rpartition(":")
        raise "Port required in endpoint: #{endpoint}" if parts[1].empty?
        host = parts[0]
        raise "Invalid IPv6 address (missing port?): #{endpoint}" if host.end_with?(":")
        port = Integer(parts[2])
        {host:, port:}
      rescue ArgumentError
        raise "Invalid port in endpoint: #{endpoint}"
      end
    end

    def start
      @thread = spawn_connectivity_check_thread
      @logger.info("[MeshConnectivity] Started mesh connectivity checker for node #{@node_id}")
    end

    def status_response
      @mutex.synchronize do
        {
          node_id: @node_id,
          pods: @pod_status.dup,
          external_endpoints: @external_status.dup
        }
      end
    end

    def spawn_connectivity_check_thread
      Thread.new do
        until @shutdown
          check_all_pods_connectivity
          check_all_external_endpoints
          write_status_file
          @queue.pop(timeout: CONNECTIVITY_CHECK_INTERVAL)
        end
      end
    end

    def check_all_pods_connectivity
      client = KubernetesClient.new(req_id: "mesh-check", logger: @logger)
      begin
        pods = client.get_nodeplugin_pods
      rescue => e
        @logger.error("[MeshConnectivity] Failed to get nodeplugin pods: #{e.message}")
        return
      end
      @logger.debug("[MeshConnectivity] Found #{pods.size} nodeplugin pods")

      targets = pods.filter_map do |pod|
        next if pod["node"] == @node_id
        next unless pod["ip"]
        {host: pod["ip"], port: REGISTRAR_HEALTHZ_PORT, name: pod["name"]}
      end

      current_pod_names = targets.map { |t| t[:name] }.to_set

      check_endpoints(targets) do |target, reachable, error|
        update_pod_status(target[:name], target[:host], reachable, error:)
      end

      # Remove stale pods that no longer exist in the cluster
      @mutex.synchronize do
        @pod_status.keep_if { |name, _| current_pod_names.include?(name) }
      end
    end

    # Checks multiple endpoints concurrently using non-blocking I/O.
    # Each target should be a hash with :host, :port, and :name keys.
    # Yields target, reachable, and optional error for each result.
    def check_endpoints(targets, &block)
      return if targets.empty?

      pending = {}
      targets.each do |target|
        result = initiate_connection(target)
        if result == :connected
          yield(target, true, nil)
          log_reachable(target)
        elsif result.respond_to?(:connect_nonblock)
          pending[result] = target
        else
          yield(target, false, result)
          log_unreachable(target, result)
        end
      end

      return if pending.empty?

      deadline = Time.now + CONNECTION_TIMEOUT
      until pending.empty?
        remaining = deadline - Time.now
        break if remaining <= 0

        _, writeable, = IO.select(nil, pending.keys, nil, remaining)
        break unless writeable

        writeable.each do |socket|
          target = pending.delete(socket)
          error = check_socket_error(socket)
          socket.close
          if error
            yield(target, false, error)
            log_unreachable(target, error)
          else
            yield(target, true, nil)
            log_reachable(target)
          end
        end
      end

      pending.each do |socket, target|
        socket.close
        yield(target, false, "Connection timed out")
        log_unreachable(target, "Connection timed out")
      end
    end

    def initiate_connection(target)
      # Resolve hostname to IP address and address family (IPv4/IPv6)
      _, _, _, ip_address, address_family, = Socket.getaddrinfo(target[:host], target[:port], nil, :STREAM).first
      # Create binary socket address structure
      sockaddr = Socket.pack_sockaddr_in(target[:port], ip_address)
      # Create TCP socket for the appropriate address family
      socket = Socket.new(address_family, :STREAM, 0)
      # Enable keepalive to detect dead connections
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
      if socket.connect_nonblock(sockaddr, exception: false) == :wait_writable
        socket
      else
        socket.close
        :connected
      end
    rescue => e
      "#{e.class}: #{e.message}"
    end

    def check_socket_error(socket)
      socket.connect_nonblock(socket.remote_address)
      nil
    rescue Errno::EISCONN
      nil # Already connected - success
    rescue => e
      "#{e.class}: #{e.message}"
    end

    def update_pod_status(name, ip, reachable, error: nil)
      hash = {
        ip:,
        reachable:,
        error:,
        last_check: Time.now.utc.iso8601
      }
      @mutex.synchronize do
        @pod_status[name] = hash
      end
    end

    def check_all_external_endpoints
      endpoints = @mutex.synchronize { @external_endpoints.dup }
      return if endpoints.empty?

      targets = endpoints.map { |ep| {host: ep[:host], port: ep[:port], name: "#{ep[:host]}:#{ep[:port]}"} }

      check_endpoints(targets) do |target, reachable, error|
        update_external_status(target[:name], reachable, error:)
      end
    end

    def update_external_status(key, reachable, error: nil)
      hash = {
        reachable:,
        error:,
        last_check: Time.now.utc.iso8601
      }
      @mutex.synchronize do
        @external_status[key] = hash
      end
    end

    def write_status_file
      dir = File.dirname(STATUS_FILE_PATH)
      Tempfile.create("mesh_status", dir) do |temp_file|
        temp_file.write(JSON.pretty_generate(status_response))
        temp_file.close
        File.rename(temp_file.path, STATUS_FILE_PATH)
        FileUtils.chmod(0o644, STATUS_FILE_PATH)
      end
    rescue => e
      @logger.error("[MeshConnectivity] Failed to write status file: #{e.message}")
    else
      @logger.debug("[MeshConnectivity] Wrote status to #{STATUS_FILE_PATH}")
    end

    private

    def log_reachable(target)
      @logger.debug("[MeshConnectivity] Pod #{target[:name]} (#{target[:host]}:#{target[:port]}) reachable")
    end

    def log_unreachable(target, error)
      @logger.warn("[MeshConnectivity] Pod #{target[:name]} (#{target[:host]}:#{target[:port]}) unreachable: #{error}")
    end
  end
end
