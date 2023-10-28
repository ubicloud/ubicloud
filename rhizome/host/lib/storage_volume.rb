# frozen_string_literal: true

require_relative "../../common/lib/util"

require "fileutils"
require "json"
require "openssl"
require "base64"
require_relative "vm_path"
require_relative "spdk_path"
require_relative "spdk_rpc"
require_relative "storage_key_encryption"

class StorageVolume
  def initialize(vm_name, params)
    @vm_name = vm_name
    @disk_index = params["disk_index"]
    @device_id = params["device_id"]
    @encrypted = params["encrypted"]
    @disk_size_gib = params["size_gib"]
    @image_path = vp.image_path(params["image"]) if params["image"]
    @disk_file = vp.disk(@disk_index)
  end

  def vp
    @vp ||= VmPath.new(@vm_name)
  end

  def rpc_client
    @rpc_client ||= SpdkRpc.new
  end

  def prep(key_wrapping_secrets)
    FileUtils.mkdir_p vp.storage(@disk_index, "")
    encryption_key = setup_data_encryption_key(key_wrapping_secrets) if @encrypted

    if @image_path.nil?
      create_empty_disk_file
      return
    end

    verify_imaged_disk_size

    if @encrypted
      encrypted_image_copy(encryption_key)
    else
      unencrypted_image_copy
    end
  end

  def start(key_wrapping_secrets)
    encryption_key = read_data_encryption_key(key_wrapping_secrets) if @encrypted

    retries = 0
    begin
      setup_spdk_bdev(encryption_key)
      setup_spdk_vhost
    rescue SpdkExists => e
      # If some of SPDK artifacts exist, purge and retry. But retry only once
      # to prevent potential retry loops.
      if retries == 0
        retries += 1
        purge_spdk_artifacts
        retry
      end
      raise e
    end
  end

  def purge_spdk_artifacts
    vhost_controller = SpdkPath.vhost_controller(@vm_name, @disk_index)

    rpc_client.vhost_delete_controller(vhost_controller)

    if @encrypted
      rpc_client.bdev_crypto_delete(@device_id)
      rpc_client.bdev_aio_delete("#{@device_id}_aio")
      rpc_client.accel_crypto_key_destroy("#{@device_id}_key")
    else
      rpc_client.bdev_aio_delete(@device_id)
    end

    rm_if_exists(SpdkPath.vhost_sock(vhost_controller))
  end

  def setup_data_encryption_key(key_wrapping_secrets)
    data_encryption_key = OpenSSL::Cipher.new("aes-256-xts").random_key.unpack1("H*")

    result = {
      cipher: "AES_XTS",
      key: data_encryption_key[..63],
      key2: data_encryption_key[64..]
    }

    key_file = vp.data_encryption_key(@disk_index)

    # save encrypted key
    sek = StorageKeyEncryption.new(key_wrapping_secrets)
    sek.write_encrypted_dek(key_file, result)

    FileUtils.chown @vm_name, @vm_name, key_file
    FileUtils.chmod "u=rw,g=,o=", key_file

    sync_parent_dir(key_file)

    result
  end

  def read_data_encryption_key(key_wrapping_secrets)
    key_file = vp.data_encryption_key(@disk_index)
    sek = StorageKeyEncryption.new(key_wrapping_secrets)
    sek.read_encrypted_dek(key_file)
  end

  def unencrypted_image_copy
    q_image_path = @image_path.shellescape
    q_disk_file = @disk_file.shellescape

    r "cp --reflink=auto #{q_image_path} #{q_disk_file}"
    r "truncate -s #{@disk_size_gib}G #{q_disk_file}"

    set_disk_file_permissions
  end

  def verify_imaged_disk_size
    size = File.size(@image_path)
    fail "Image size greater than requested disk size" unless size <= @disk_size_gib * 2**30
  end

  def encrypted_image_copy(encryption_key)
    # Note that spdk_dd doesn't interact with the main spdk process. It is a
    # tool which starts the spdk infra as a separate process, creates bdevs
    # from config, does the copy, and exits. Since it is a separate process
    # for each image, although bdev names are same, they don't conflict.
    # Goal is to copy the image into disk_file, which will be registered
    # in the main spdk daemon after this function returns.

    bdev_conf = [{
      method: "bdev_aio_create",
      params: {
        name: "aio0",
        block_size: 512,
        filename: @disk_file,
        readonly: false
      }
    },
      {
        method: "bdev_crypto_create",
        params: {
          base_bdev_name: "aio0",
          name: "crypt0",
          key_name: "super_key"
        }
      }]

    accel_conf = [
      {
        method: "accel_crypto_key_create",
        params: {
          name: "super_key",
          cipher: encryption_key[:cipher],
          key: encryption_key[:key],
          key2: encryption_key[:key2]
        }
      }
    ]

    spdk_config_json = {
      subsystems: [
        {
          subsystem: "accel",
          config: accel_conf
        },
        {
          subsystem: "bdev",
          config: bdev_conf
        }
      ]
    }.to_json

    # spdk_dd uses the same spdk app infra, so it will bind to an rpc socket,
    # which we won't use. But its path shouldn't conflict with other VM setups,
    # so it doesn't error out in concurrent VM creations.
    rpc_socket = "/var/tmp/spdk_dd.sock.#{@vm_name}"

    create_empty_disk_file

    r("#{SpdkPath.bin("spdk_dd")} --config /dev/stdin " \
    "--disable-cpumask-locks " \
    "--rpc-socket #{rpc_socket.shellescape} " \
    "--if #{@image_path.shellescape} " \
    "--ob crypt0 " \
    "--bs=2097152", stdin: spdk_config_json)
  end

  def create_empty_disk_file
    FileUtils.touch(@disk_file)
    r "truncate -s #{@disk_size_gib}G #{@disk_file.shellescape}"

    set_disk_file_permissions
  end

  def set_disk_file_permissions
    FileUtils.chown @vm_name, @vm_name, @disk_file

    # don't allow others to read user's disk
    FileUtils.chmod "u=rw,g=r,o=", @disk_file

    # allow spdk to access the image
    r "setfacl -m u:spdk:rw #{@disk_file.shellescape}"
  end

  def setup_spdk_bdev(encryption_key)
    bdev = @device_id

    if encryption_key
      key_name = "#{bdev}_key"
      aio_bdev = "#{bdev}_aio"
      rpc_client.accel_crypto_key_create(
        key_name,
        encryption_key[:cipher],
        encryption_key[:key],
        encryption_key[:key2]
      )
      rpc_client.bdev_aio_create(aio_bdev, @disk_file, 512)
      rpc_client.bdev_crypto_create(bdev, aio_bdev, key_name)
    else
      rpc_client.bdev_aio_create(bdev, @disk_file, 512)
    end
  end

  def setup_spdk_vhost
    vhost_controller = SpdkPath.vhost_controller(@vm_name, @disk_index)
    spdk_vhost_sock = SpdkPath.vhost_sock(vhost_controller)

    rpc_client.vhost_create_blk_controller(vhost_controller, @device_id)

    # don't allow others to access the vhost socket
    FileUtils.chmod "u=rw,g=r,o=", spdk_vhost_sock

    # allow vm user to access the vhost socket
    r "setfacl -m u:#{@vm_name}:rw #{spdk_vhost_sock.shellescape}"

    # create a symlink to the socket in the per vm storage dir
    rm_if_exists(vp.vhost_sock(@disk_index))
    FileUtils.ln_s spdk_vhost_sock, vp.vhost_sock(@disk_index)

    # Change ownership of the symlink. FileUtils.chown uses File.lchown for
    # symlinks and doesn't follow links. We don't use File.lchown directly
    # because it expects numeric uid & gid, which is less convenient.
    FileUtils.chown @vm_name, @vm_name, vp.vhost_sock(@disk_index)

    vp.vhost_sock(@disk_index)
  end
end
