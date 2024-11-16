# frozen_string_literal: true

require_relative "spdk_path"

class SpdkRpc
  def initialize(socket_path, timeout = 5, response_size_limit = 1048576)
    @socket_path = socket_path
    @timeout = timeout
    @response_size_limit = response_size_limit
  end

  def bdev_aio_create(name, filename, block_size)
    params = {
      name: name,
      filename: filename,
      block_size: block_size,
      readonly: false
    }
    call("bdev_aio_create", params)
  end

  def bdev_aio_delete(name, if_exists = true)
    call("bdev_aio_delete", {name: name})
  rescue SpdkNotFound
    raise unless if_exists
  end

  def bdev_crypto_create(name, base_bdev_name, key_name)
    params = {
      name: name,
      base_bdev_name: base_bdev_name,
      key_name: key_name
    }
    call("bdev_crypto_create", params)
  end

  def bdev_crypto_delete(name, if_exists = true)
    call("bdev_crypto_delete", {name: name})
  rescue SpdkNotFound
    raise unless if_exists
  end

  def bdev_ubi_create(name, base_bdev_name, image_path,
    skip_sync = false,
    stripe_size_kb = 1024,
    copy_on_read = false,
    directio = true)
    params = {
      name: name,
      base_bdev: base_bdev_name,
      image_path: image_path,
      stripe_size_kb: stripe_size_kb,
      no_sync: skip_sync,
      copy_on_read: copy_on_read,
      directio: directio
    }
    call("bdev_ubi_create", params)
  end

  def bdev_ubi_delete(name, if_exists = true)
    call("bdev_ubi_delete", {name: name})
  rescue SpdkNotFound
    raise unless if_exists
  end

  def vhost_create_blk_controller(name, bdev)
    params = {
      ctrlr: name,
      dev_name: bdev
    }
    call("vhost_create_blk_controller", params)
  end

  def vhost_delete_controller(name, if_exists = true)
    call("vhost_delete_controller", {ctrlr: name})
  rescue SpdkNotFound
    raise unless if_exists
  end

  def accel_crypto_key_create(name, cipher, key, key2)
    params = {
      name: name,
      cipher: cipher,
      key: key,
      key2: key2
    }
    call("accel_crypto_key_create", params)
  end

  def accel_crypto_key_destroy(name, if_exists = true)
    call("accel_crypto_key_destroy", {key_name: name})
  rescue SpdkNotFound
    raise unless if_exists
  end

  def bdev_set_qos_limit(name, rw_ios_per_sec: nil, r_mbytes_per_sec: nil, w_mbytes_per_sec: nil)
    # SPDK expects 0 to be passed if there is no limit.
    params = {
      name: name,
      rw_ios_per_sec: rw_ios_per_sec || 0,
      r_mbytes_per_sec: r_mbytes_per_sec || 0,
      w_mbytes_per_sec: w_mbytes_per_sec || 0
    }
    call("bdev_set_qos_limit", params)
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
      raise SpdkRpcError.build(err.fetch("message"), err.fetch("code"))
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

class SpdkRpcError < StandardError
  attr_reader :code

  def initialize(message, code)
    super(message)
    @code = code
  end

  def self.build(message, code)
    # Check if we can return a specific subclass.
    case code
    when -Errno::EEXIST::Errno
      return SpdkExists.new(message, code)
    when -Errno::ENODEV::Errno
      return SpdkNotFound.new(message, code)
    when -32602 # SPDK_JSONRPC_ERROR_INVALID_PARAMS
      if message.match?(/File exists|rc -17/)
        return SpdkExists.new(message, code)
      elsif message.match?(/No key object found|No such device/)
        return SpdkNotFound.new(message, code)
      end
    end

    SpdkRpcError.new(message, code)
  end
end

class SpdkExists < SpdkRpcError
end

class SpdkNotFound < SpdkRpcError
end
