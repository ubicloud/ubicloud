# frozen_string_literal: true

require_relative "../lib/spdk_rpc"
require_relative "../../common/lib/util"
require "fileutils"

return if ENV["RUN_E2E_TESTS"] != "1"

RSpec.describe SpdkRpc do
  subject(:spdk_rpc) {
    socket = ENV["SPDK_TESTS_RPC_SOCKET"] || SpdkPath.rpc_sock(DEFAULT_SPDK_VERSION)
    described_class.new(socket)
  }

  let(:filename) {
    tmp_dir = ENV["SPDK_TESTS_TMP_DIR"] || "/tmp"
    "#{tmp_dir}/#{random_name("disk_file")}"
  }

  before do
    FileUtils.touch(filename)
    r "truncate --size 5M #{filename}"
    FileUtils.chmod 0o777, filename
  end

  after do
    FileUtils.rm_rf(filename)
  end

  def random_name(prefix)
    "#{prefix}_#{rand(2**32)}"
  end

  describe "#bdev_aio" do
    it "can create and delete a bdev_aio" do
      name = random_name("aio")
      spdk_rpc.bdev_aio_create(name, filename, 512)
      expect { spdk_rpc.bdev_aio_delete(name) }.not_to raise_error
    end

    it "raises an exception if bdev to be created already exists" do
      name = random_name("aio")
      spdk_rpc.bdev_aio_create(name, filename, 512)
      expect {
        spdk_rpc.bdev_aio_create(name, filename, 512)
      }.to raise_error SpdkExists
      spdk_rpc.bdev_aio_delete(name)
    end

    it "skips deleting by default if bdev doesn't exist" do
      name = random_name("aio")
      expect { spdk_rpc.bdev_aio_delete(name) }.not_to raise_error
    end

    it "raises exception if bdev to deleted doesn't exist and if_exists=false" do
      name = random_name("aio")
      expect {
        spdk_rpc.bdev_aio_delete(name, false)
      }.to raise_error SpdkNotFound
    end

    it "raises an exception if params are not good" do
      name = random_name("aio")
      expect {
        spdk_rpc.bdev_aio_create(name, filename, -1)
      }.to raise_error SpdkRpcError
    end
  end

  describe "#accel_crypto_key" do
    let(:key) { "0123456789abcdef0123456789abcdef" }
    let(:key2) { "fedcba9876543210fedcba9876543210" }
    let(:cipher) { "AES_XTS" }

    it "can create and delete a key" do
      name = random_name("key")
      spdk_rpc.accel_crypto_key_create(name, cipher, key, key2)
      expect { spdk_rpc.accel_crypto_key_destroy(name) }.not_to raise_error
    end

    it "raises an exception if key to be created already exists" do
      name = random_name("key")
      spdk_rpc.accel_crypto_key_create(name, cipher, key, key2)
      expect {
        spdk_rpc.accel_crypto_key_create(name, cipher, key, key2)
      }.to raise_error SpdkExists
      spdk_rpc.accel_crypto_key_destroy(name)
    end

    it "skips deleting by default if key doesn't exist" do
      name = random_name("key")
      expect { spdk_rpc.accel_crypto_key_destroy(name) }.not_to raise_error
    end

    it "raises exception if key to deleted doesn't exist and if_exists=false" do
      name = random_name("key")
      expect {
        spdk_rpc.accel_crypto_key_destroy(name, false)
      }.to raise_error SpdkNotFound
    end

    it "raises an exception if params are not good" do
      name = random_name("key")
      expect {
        spdk_rpc.accel_crypto_key_create(name, "ABC", key, key2)
      }.to raise_error SpdkRpcError
    end
  end

  describe "#bdev_crypto" do
    let(:key_name) { random_name("key") }
    let(:base_bdev) { random_name("aio") }

    before do
      spdk_rpc.accel_crypto_key_create(
        key_name,
        "AES_XTS",
        "0123456789abcdef0123456789abcdef",
        "fedcba9876543210fedcba9876543210"
      )
      spdk_rpc.bdev_aio_create(base_bdev, filename, 512)
    end

    after do
      spdk_rpc.accel_crypto_key_destroy(key_name)
      spdk_rpc.bdev_aio_delete(base_bdev)
    end

    it "can create and delete a bdev_crypto" do
      name = random_name("crypto")
      spdk_rpc.bdev_crypto_create(name, base_bdev, key_name)
      expect { spdk_rpc.bdev_crypto_delete(name) }.not_to raise_error
    end

    it "raises an exception if bdev to be created already exists" do
      name = random_name("crypto")
      spdk_rpc.bdev_crypto_create(name, base_bdev, key_name)
      expect {
        spdk_rpc.bdev_crypto_create(name, base_bdev, key_name)
      }.to raise_error SpdkExists
      spdk_rpc.bdev_crypto_delete(name)
    end

    it "skips deleting by default if bdev doesn't exist" do
      name = random_name("crypto")
      expect { spdk_rpc.bdev_crypto_delete(name) }.not_to raise_error
    end

    it "raises exception if bdev to deleted doesn't exist and if_exists=false" do
      name = random_name("crypto")
      expect {
        spdk_rpc.bdev_crypto_delete(name, false)
      }.to raise_error SpdkNotFound
    end

    it "raises an exception if params are not good" do
      name = random_name("crypto")
      expect {
        spdk_rpc.bdev_crypto_create(name, base_bdev, "xyz")
      }.to raise_error SpdkRpcError
    end
  end

  describe "#vhost_blk_controller" do
    let(:bdev) { random_name("aio") }

    before do
      spdk_rpc.bdev_aio_create(bdev, filename, 512)
    end

    after do
      spdk_rpc.bdev_aio_delete(bdev)
    end

    it "can create and delete a vhost controller" do
      name = random_name("vhost")
      spdk_rpc.vhost_create_blk_controller(name, bdev)
      expect { spdk_rpc.vhost_delete_controller(name) }.not_to raise_error
    end

    it "raises an exception if bdev to be created already exists" do
      name = random_name("vhost")
      spdk_rpc.vhost_create_blk_controller(name, bdev)
      expect {
        spdk_rpc.vhost_create_blk_controller(name, bdev)
      }.to raise_error SpdkExists
      spdk_rpc.vhost_delete_controller(name)
    end

    it "skips deleting by default if bdev doesn't exist" do
      name = random_name("vhost")
      expect { spdk_rpc.vhost_delete_controller(name) }.not_to raise_error
    end

    it "raises exception if bdev to deleted doesn't exist and if_exists=false" do
      name = random_name("vhost")
      expect {
        spdk_rpc.vhost_delete_controller(name, false)
      }.to raise_error SpdkNotFound
    end

    it "raises an exception if params are not good" do
      name = random_name("vhost")
      expect {
        spdk_rpc.vhost_create_blk_controller(name, "asdf")
      }.to raise_error SpdkRpcError
    end
  end
end
