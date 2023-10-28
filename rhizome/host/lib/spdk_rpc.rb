# frozen_string_literal: true

require_relative "spdk_path"
require_relative "json_rpc_client"

class SpdkRpc
  def client
    @client ||= JsonRpcClient.new(SpdkPath.rpc_sock)
  end

  def rpc_call(name, params)
    client.call(name, params)
  rescue JsonRpcError => e
    raise SpdkRpcError.from_json_rpc_error(e)
  end

  def bdev_aio_create(name, filename, block_size)
    params = {
      name: name,
      filename: filename,
      block_size: block_size,
      readonly: false
    }
    rpc_call("bdev_aio_create", params)
  end

  def bdev_aio_delete(name, if_exists = true)
    rpc_call("bdev_aio_delete", {name: name})
  rescue SpdkNotFound => e
    raise e unless if_exists
  end

  def bdev_crypto_create(name, base_bdev_name, key_name)
    params = {
      name: name,
      base_bdev_name: base_bdev_name,
      key_name: key_name
    }
    rpc_call("bdev_crypto_create", params)
  end

  def bdev_crypto_delete(name, if_exists = true)
    rpc_call("bdev_crypto_delete", {name: name})
  rescue SpdkNotFound => e
    raise e unless if_exists
  end

  def vhost_create_blk_controller(name, bdev)
    params = {
      ctrlr: name,
      dev_name: bdev
    }
    rpc_call("vhost_create_blk_controller", params)
  end

  def vhost_delete_controller(name, if_exists = true)
    rpc_call("vhost_delete_controller", {ctrlr: name})
  rescue SpdkNotFound => e
    raise e unless if_exists
  end

  def accel_crypto_key_create(name, cipher, key, key2)
    params = {
      name: name,
      cipher: cipher,
      key: key,
      key2: key2
    }
    rpc_call("accel_crypto_key_create", params)
  end

  def accel_crypto_key_destroy(name, if_exists = true)
    rpc_call("accel_crypto_key_destroy", {key_name: name})
  rescue SpdkNotFound => e
    raise e unless if_exists
  end
end

class SpdkRpcError < StandardError
  attr_reader :code

  def initialize(message, code)
    super(message)
    @code = code
  end

  def self.from_json_rpc_error(e)
    # Check if we can return a specific subclass.
    case e.code
    when -Errno::EEXIST::Errno
      return SpdkExists.new(e.message, e.code)
    when -Errno::ENODEV::Errno
      return SpdkNotFound.new(e.message, e.code)
    when -32602 # SPDK_JSONRPC_ERROR_INVALID_PARAMS
      if e.message.match?(/File exists|rc -17/)
        return SpdkExists.new(e.message, e.code)
      elsif e.message.match?(/No key object found|No such device/)
        return SpdkNotFound.new(e.message, e.code)
      end
    end

    SpdkRpcError.new(e.message, e.code)
  end
end

class SpdkExists < SpdkRpcError
end

class SpdkNotFound < SpdkRpcError
end
