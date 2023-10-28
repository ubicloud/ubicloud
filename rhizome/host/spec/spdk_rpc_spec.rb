# frozen_string_literal: true

require_relative "../lib/spdk_rpc"

RSpec.describe SpdkRpc do
  subject(:sr) {
    described_class.new
  }

  let(:rpc_client) {
    instance_double(JsonRpcClient)
  }

  before do
    allow(sr).to receive(:client).and_return(rpc_client)
  end

  describe "#bdev_aio_create" do
    it "can create an aio bdev" do
      expect(rpc_client).to receive(:call).with("bdev_aio_create", {
        name: "name",
        filename: "filename",
        block_size: 512,
        readonly: false
      })
      sr.bdev_aio_create("name", "filename", 512)
    end
  end

  describe "#bdev_aio_delete" do
    it "can delete an aio bdev" do
      expect(rpc_client).to receive(:call).with("bdev_aio_delete", {
        name: "name"
      })
      sr.bdev_aio_delete("name")
    end

    it "ignores exception if bdev doesn't exist and if_exists=true" do
      expect(rpc_client).to receive(:call).with("bdev_aio_delete", {
        name: "name"
      }).and_raise JsonRpcError.new("No such device", -19)
      sr.bdev_aio_delete("name")
    end

    it "raises exception if bdev doesn't exist and if_exists=false" do
      expect(rpc_client).to receive(:call).with("bdev_aio_delete", {
        name: "name"
      }).and_raise JsonRpcError.new("No such device", -19)
      expect { sr.bdev_aio_delete("name", false) }.to raise_error SpdkNotFound
    end
  end

  describe "#bdev_crypto_create" do
    it "can create an crypto bdev" do
      expect(rpc_client).to receive(:call).with("bdev_crypto_create", {
        name: "name",
        base_bdev_name: "base",
        key_name: "key"
      })
      sr.bdev_crypto_create("name", "base", "key")
    end
  end

  describe "#bdev_crypto_delete" do
    it "can delete an crypto bdev" do
      expect(rpc_client).to receive(:call).with("bdev_crypto_delete", {
        name: "name"
      })
      sr.bdev_crypto_delete("name")
    end

    it "ignores exception if bdev doesn't exist and if_exists=true" do
      expect(rpc_client).to receive(:call).with("bdev_crypto_delete", {
        name: "name"
      }).and_raise JsonRpcError.new("No such device", -19)
      sr.bdev_crypto_delete("name")
    end

    it "raises exception if bdev doesn't exist and if_exists=false" do
      expect(rpc_client).to receive(:call).with("bdev_crypto_delete", {
        name: "name"
      }).and_raise JsonRpcError.new("No such device", -19)
      expect { sr.bdev_crypto_delete("name", false) }.to raise_error SpdkNotFound
    end
  end

  describe "#vhost_create_blk_controller" do
    it "can create a vhost block controller" do
      expect(rpc_client).to receive(:call).with("vhost_create_blk_controller", {
        ctrlr: "name",
        dev_name: "bdev"
      })
      sr.vhost_create_blk_controller("name", "bdev")
    end

    it "raises SpdkExists if device already exists" do
      expect(rpc_client).to receive(:call).with("vhost_create_blk_controller", {
        ctrlr: "name",
        dev_name: "bdev"
      }).and_raise JsonRpcError.new("File exists", -32602)
      expect { sr.vhost_create_blk_controller("name", "bdev") }.to raise_error SpdkExists
    end

    it "raises SpdkNotFound for other errors" do
      expect(rpc_client).to receive(:call).with("vhost_create_blk_controller", {
        ctrlr: "name",
        dev_name: "bdev"
      }).and_raise JsonRpcError.new("No such device", -32602)
      expect { sr.vhost_create_blk_controller("name", "bdev") }.to raise_error SpdkNotFound
    end
  end

  describe "#vhost_delete_controller" do
    it "can delete an vhost controller" do
      expect(rpc_client).to receive(:call).with("vhost_delete_controller", {
        ctrlr: "name"
      })
      sr.vhost_delete_controller("name")
    end

    it "ignores exception if controller doesn't exist and if_exists=true" do
      expect(rpc_client).to receive(:call).with("vhost_delete_controller", {
        ctrlr: "name"
      }).and_raise JsonRpcError.new("No such device", -32602)
      sr.vhost_delete_controller("name")
    end

    it "raises exception if controller doesn't exist and if_exists=false" do
      expect(rpc_client).to receive(:call).with("vhost_delete_controller", {
        ctrlr: "name"
      }).and_raise JsonRpcError.new("No such device", -32602)
      expect { sr.vhost_delete_controller("name", false) }.to raise_error SpdkNotFound
    end
  end

  describe "#accel_crypto_key_create" do
    it "can create a crypto key" do
      expect(rpc_client).to receive(:call).with("accel_crypto_key_create", {
        name: "name",
        cipher: "cipher",
        key: "key",
        key2: "key2"
      })
      sr.accel_crypto_key_create("name", "cipher", "key", "key2")
    end

    it "raises SpdkExists if key exists" do
      expect(rpc_client).to receive(:call).with("accel_crypto_key_create", {
        name: "name",
        cipher: "cipher",
        key: "key",
        key2: "key2"
      }).and_raise JsonRpcError.new("failed to create DEK, rc -17", -32602)
      expect {
        sr.accel_crypto_key_create("name", "cipher", "key", "key2")
      }.to raise_error SpdkExists
    end

    it "raises SpdkRpcError for other errors" do
      expect(rpc_client).to receive(:call).with("accel_crypto_key_create", {
        name: "name",
        cipher: "cipher",
        key: "key",
        key2: "key2"
      }).and_raise JsonRpcError.new("failed to create DEK, rc -22", -32602)
      expect {
        sr.accel_crypto_key_create("name", "cipher", "key", "key2")
      }.to raise_error SpdkRpcError, "failed to create DEK, rc -22"
    end
  end

  describe "#accel_crypto_key_destroy" do
    it "can delete an crypto key" do
      expect(rpc_client).to receive(:call).with("accel_crypto_key_destroy", {
        key_name: "name"
      })
      sr.accel_crypto_key_destroy("name")
    end

    it "ignores exception if crypto key doesn't exist and if_exists=true" do
      expect(rpc_client).to receive(:call).with("accel_crypto_key_destroy", {
        key_name: "name"
      }).and_raise JsonRpcError.new("No key object found", -32602)
      sr.accel_crypto_key_destroy("name")
    end

    it "raises exception if crypto key doesn't exist and if_exists=false" do
      expect(rpc_client).to receive(:call).with("accel_crypto_key_destroy", {
        key_name: "name"
      }).and_raise JsonRpcError.new("No key object found", -32602)
      expect { sr.accel_crypto_key_destroy("name", false) }.to raise_error SpdkNotFound
    end
  end
end
