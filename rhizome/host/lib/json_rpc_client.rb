# frozen_string_literal: true

require "json"
require "socket"

class JsonRpcError < StandardError
  attr_reader :code

  def initialize(message, code)
    super(message)
    @code = code
  end
end

class JsonRpcClient
  def initialize(socket_path, timeout = 5, response_size_limit = 1048576)
    @socket_path = socket_path
    @timeout = timeout
    @response_size_limit = response_size_limit
  end

  def call(method, params = {})
    # id is used to correlate the context between request and response.
    # See https://www.jsonrpc.org/specification
    id = rand(10000000)

    payload = {
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: id
    }

    unix_socket = UNIXSocket.new(@socket_path)
    unix_socket.write_nonblock(payload.to_json + "\n")

    response = JSON.parse(read_response(unix_socket))
    if (err = response["error"])
      raise JsonRpcError.new(err.fetch("message"), err.fetch("code"))
    end

    unix_socket.close

    response["result"]
  end

  def read_response(socket)
    buffer = +""
    start_time = Time.now

    begin
      # Use IO.select to wait for data with a timeout. Subtract elapsed time,
      # since this can be called multiple times.
      elapsed_time = Time.now - start_time
      ready_sockets = IO.select([socket], nil, nil, @timeout - elapsed_time)

      # If ready_sockets is nil, it means timeout occurred
      unless ready_sockets
        socket.close
        raise "The request timed out after #{@timeout} seconds."
      end

      # Loop until the whole JSON response is received.
      loop do
        buffer << socket.read_nonblock(4096)
        break if valid_json?(buffer)
        raise "Response size limit exceeded." if buffer.length > @response_size_limit
      end
    rescue IO::WaitReadable
      retry
    end

    buffer
  end

  def valid_json?(json_str)
    JSON.parse(json_str)
    true
  rescue JSON::ParserError
    false
  end
end
