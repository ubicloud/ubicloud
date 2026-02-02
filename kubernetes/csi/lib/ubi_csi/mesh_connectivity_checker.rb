# frozen_string_literal: true

require "socket"
require_relative "kubernetes_client"

module Csi
  class MeshConnectivityChecker
    CONNECTIVITY_CHECK_INTERVAL = 30
    CONNECTION_TIMEOUT = 5
    REGISTRAR_HEALTHZ_PORT = 8080

    def initialize(logger:, node_id:)
      @logger = logger
      @node_id = node_id
      @queue = Queue.new
      @shutdown = false
    end

    def shutdown!
      @shutdown = true
      @queue.close
      @thread&.join
    end

    def start
      @thread = spawn_connectivity_check_thread
      @logger.info("[MeshConnectivity] Started mesh connectivity checker for node #{@node_id}")
    end

    def spawn_connectivity_check_thread
      Thread.new do
        until @shutdown
          check_all_pods_connectivity
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
        {host: pod["ip"], port: REGISTRAR_HEALTHZ_PORT, label: "Pod #{pod["name"]}"}
      end

      check_endpoints(targets)
    end

    # Checks multiple endpoints concurrently using non-blocking I/O.
    # Each target should be a hash with :host, :port, and :label keys.
    def check_endpoints(targets)
      return if targets.empty?

      pending = {}
      targets.each do |target|
        result = initiate_connection(target)
        if result == :connected
          log_reachable(target)
        elsif result.respond_to?(:connect_nonblock)
          pending[result] = target
        else
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
            log_unreachable(target, error)
          else
            log_reachable(target)
          end
        end
      end

      pending.each do |socket, target|
        socket.close
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

    def log_reachable(target)
      @logger.debug("[MeshConnectivity] #{target[:label]} (#{target[:host]}:#{target[:port]}) reachable")
    end

    def log_unreachable(target, error)
      @logger.warn("[MeshConnectivity] #{target[:label]} (#{target[:host]}:#{target[:port]}) unreachable: #{error}")
    end
  end
end
