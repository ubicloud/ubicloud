# frozen_string_literal: true

require_relative "spdk_path"
require_relative "json_rpc_client"

class SpdkRpc
  def client
    @client ||= JsonRpcClient.new(SpdkPath.rpc_sock)
  end

  def bdev_aio_create(name, filename, block_size)
    params = {
      name: name,
      filename: filename,
      block_size: block_size,
      readonly: false
    }
    client.call("bdev_aio_create", params)
  end

  def bdev_aio_delete(name, if_exists = true)
    client.call("bdev_aio_delete", {name: name})
  rescue JsonRpcError => e
    raise e unless if_exists && e.message.include?("No such device")
  end

  def bdev_crypto_create(name, base_bdev_name, key_name)
    params = {
      name: name,
      base_bdev_name: base_bdev_name,
      key_name: key_name
    }
    client.call("bdev_crypto_create", params)
  end

  def bdev_crypto_delete(name, if_exists = true)
    client.call("bdev_crypto_delete", {name: name})
  rescue JsonRpcError => e
    raise e unless if_exists && e.message.include?("No such device")
  end

  def vhost_create_blk_controller(name, bdev)
    params = {
      ctrlr: name,
      dev_name: bdev
    }
    client.call("vhost_create_blk_controller", params)
  end

  def vhost_delete_controller(name, if_exists = true)
    client.call("vhost_delete_controller", {ctrlr: name})
  rescue JsonRpcError => e
    raise e unless if_exists && e.message.include?("No such device")
  end

  def accel_crypto_key_create(name, cipher, key, key2)
    params = {
      name: name,
      cipher: cipher,
      key: key,
      key2: key2
    }
    client.call("accel_crypto_key_create", params)
  end

  def accel_crypto_key_destroy(name, if_exists = true)
    client.call("accel_crypto_key_destroy", {key_name: name})
  rescue JsonRpcError => e
    raise e unless if_exists && e.message.include?("No key object found")
  end
end
